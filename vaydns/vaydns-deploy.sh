#!/bin/bash

# vaydns Server Setup Script
# Supports Fedora, Rocky, CentOS, Debian, Ubuntu

set -e

# Menu (menu.sh) calls this script directly with no "Press Enter" pause
# and immediately clear()s the screen for the next redraw - so on any
# early exit() (root check, dnstt conflict, etc.) or even after a
# successful run, the message flashes and disappears before it can be
# read. Pause on exit, success or failure, so it's actually visible.
trap 'echo ""; read -rp "Pindutin ang Enter para bumalik sa menu... " _' EXIT

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "\033[0;31m[ERROR]\033[0m This script must be run as root"
    exit 1
fi

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
SCRIPT_URL="https://raw.githubusercontent.com/noelrubio143/aaa/main/vaydns/vaydns-deploy.sh"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/vaydns"
SYSTEMD_DIR="/etc/systemd/system"
VAYDNS_USER="vaydns"
SCRIPT_INSTALL_PATH="/usr/local/bin/vaydns-deploy"
BUILD_DIR="/opt/vaydns"
VAYDNS_PORT="5310"

# Two independent vaydns instances share one binary and one service user:
#   ssh   -> vaydns-server (UDP 5310) -> local SSH port
#   xray  -> vaydns-xray   (UDP 5311) -> Xray vless/tcp inbound 127.0.0.1:14019
#   ovpn  -> vaydns-ovpn   (UDP 5312) -> OpenVPN (tcp) 127.0.0.1:1194
#   all   -> vaydns-all (UDP 5313) -> gomux edge 127.0.0.1:80 (SSH + OpenVPN + Xray ws paths, one domain)
# Public UDP/53 is split between them by the domain inside the DNS query
# (iptables string match), so each instance needs its own domain.
ALL_COMPS=(ssh xray ovpn all)
SSH_PORT_VAY="5310"
XRAY_PORT_VAY="5311"
OVPN_PORT_VAY="5312"
ALL_PORT_VAY="5313"
ALL_TARGET_PORT="80"
OVPN_TARGET_PORT="1194"
XRAY_TARGET_PORT="14019"
SSH_SERVICE="vaydns-server"
XRAY_SERVICE="vaydns-xray"
OVPN_SERVICE="vaydns-ovpn"
ALL_SERVICE="vaydns-all"
SSH_CONFIG_FILE="${CONFIG_DIR}/vaydns-server.conf"
XRAY_CONFIG_FILE="${CONFIG_DIR}/vaydns-xray.conf"
OVPN_CONFIG_FILE="${CONFIG_DIR}/vaydns-ovpn.conf"
ALL_CONFIG_FILE="${CONFIG_DIR}/vaydns-all.conf"
XRAY_JSON="/etc/xray/config.json"
NAT_APPLY_SCRIPT="/usr/local/bin/vaydns-nat-apply"
COMP="ssh"

# Per-source-IP cap on incoming UDP/53 DNS queries, applied before the
# domain-match redirect so a flooding client can't hit the string match
# on every packet. Generous headroom for normal/heavy legitimate use;
# this is meant to stop a single abusive client, not throttle real users.
RATE_LIMIT_QPS="150"     # sustained queries/sec per source IP
RATE_LIMIT_BURST="300"   # short burst allowance per source IP

comp_service() { case "$1" in xray) echo "$XRAY_SERVICE" ;; ovpn) echo "$OVPN_SERVICE" ;; all) echo "$ALL_SERVICE" ;; *) echo "$SSH_SERVICE" ;; esac; }
comp_conf()    { case "$1" in xray) echo "$XRAY_CONFIG_FILE" ;; ovpn) echo "$OVPN_CONFIG_FILE" ;; all) echo "$ALL_CONFIG_FILE" ;; *) echo "$SSH_CONFIG_FILE" ;; esac; }
comp_port()    { case "$1" in xray) echo "$XRAY_PORT_VAY" ;; ovpn) echo "$OVPN_PORT_VAY" ;; all) echo "$ALL_PORT_VAY" ;; *) echo "$SSH_PORT_VAY" ;; esac; }
comp_label()   { case "$1" in xray) echo "Xray vless" ;; ovpn) echo "OpenVPN" ;; all) echo "ALL-in-one (gomux)" ;; *) echo "SSH" ;; esac; }
comp_domain()  { local f; f=$(comp_conf "$1"); if [ -f "$f" ]; then grep '^DOMAIN=' "$f" | cut -d'"' -f2; fi; return 0; }

# Select which instance (ssh | xray | ovpn | all) the following functions operate on.
set_component() {
    COMP="$1"
    case "$COMP" in xray|ovpn|all) ;; *) COMP="ssh" ;; esac
    VAYDNS_PORT=$(comp_port "$COMP")
    SERVICE_NAME=$(comp_service "$COMP")
    CONFIG_FILE=$(comp_conf "$COMP")
    TUNNEL_MODE="$COMP"
}

# Global variable to track if update is available

# Print functions
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_question() {
    echo -ne "${BLUE}[QUESTION]${NC} $1"
}

# Replace the systemd-resolved stub resolv.conf with a real file
fix_resolv_conf() {
    if [ -L /etc/resolv.conf ] || ! grep -q '^nameserver' /etc/resolv.conf 2>/dev/null \
        || grep -q '^nameserver 127\.0\.0\.53' /etc/resolv.conf 2>/dev/null; then
        print_warning "Fixing /etc/resolv.conf (setting 8.8.8.8 / 1.1.1.1)..."
        chattr -i /etc/resolv.conf 2>/dev/null || true
        rm -f /etc/resolv.conf
        printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf
        chattr +i /etc/resolv.conf 2>/dev/null || true
    fi
}

# Clean up DNS service conflicts (systemd-resolved, dnsmasq, etc)
cleanup_dns_conflicts() {
    print_status "Checking for DNS service conflicts..."
    
    # Disable systemd-resolved
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        print_warning "Disabling systemd-resolved..."
        systemctl stop systemd-resolved 2>/dev/null || true
        systemctl disable systemd-resolved 2>/dev/null || true
        systemctl mask systemd-resolved 2>/dev/null || true
    fi

    # Always make sure the VPS keeps a working DNS (resolv.conf may still be a
    # symlink to the systemd-resolved stub 127.0.0.53, which breaks curl/wget)
    fix_resolv_conf
    
    # Kill conflicting DNS services
    for dns_srv in dnsmasq pdnsd unbound; do
        if pgrep -x "$dns_srv" > /dev/null 2>&1; then
            print_warning "Stopping $dns_srv..."
            killall "$dns_srv" 2>/dev/null || true
        fi
    done
}

# Function to install/update the script itself
install_script() {
    print_status "Installing/updating vaydns-deploy script..."

    # Download the latest version
    local temp_script="/tmp/vaydns-deploy-new.sh"
    curl -Ls "$SCRIPT_URL" -o "$temp_script"

    # Make it executable
    chmod +x "$temp_script"

    # Check if we're updating an existing installation
    if [ -f "$SCRIPT_INSTALL_PATH" ]; then
        # Compare checksums to see if update is needed
        local current_checksum
        local new_checksum
        current_checksum=$(sha256sum "$SCRIPT_INSTALL_PATH" | cut -d' ' -f1)
        new_checksum=$(sha256sum "$temp_script" | cut -d' ' -f1)

        if [ "$current_checksum" = "$new_checksum" ]; then
            print_status "Script is already up to date"
            rm "$temp_script"
            return 0
        else
            print_status "Updating existing script installation..."
        fi
    else
        print_status "Installing script for the first time..."
    fi

    # Copy to installation directory
    cp "$temp_script" "$SCRIPT_INSTALL_PATH"
    rm "$temp_script"

    print_status "Script installed to $SCRIPT_INSTALL_PATH"
    print_status "You can now run 'vaydns-deploy' from anywhere"
}

# Function to show main menu
show_menu() {
    echo ""
    print_status "vaydns Server Management"
    print_status "=================================="

    echo "1) Install/Reconfigure vaydns - SSH (UDP 5310)"
    echo "2) Install/Reconfigure vaydns - Xray vless/tcp (UDP 5311)"
    echo "3) Install/Reconfigure vaydns - OpenVPN tcp (UDP 5312)"
    echo "4) Install/Reconfigure vaydns - ALL-in-one: SSH + OpenVPN + Xray ws (UDP 5313)"
    echo "0) Exit"
    echo ""
    print_question "Please select an option (0-4): "
}

# Function to handle menu selection
handle_menu() {
    while true; do
        show_menu
        read -r choice

        local pick_comp=""
        case $choice in
            1) pick_comp="ssh" ;;
            2) pick_comp="xray" ;;
            3) pick_comp="ovpn" ;;
            4) pick_comp="all" ;;
            0)
                print_status "Goodbye!"
                exit 0
                ;;
            *)
                print_error "Invalid choice. Please enter 0-4."
                ;;
        esac

        if [ -n "$pick_comp" ]; then
            set_component "$pick_comp"
            print_status "Starting $(comp_label "$pick_comp") vaydns installation/reconfiguration..."
            return 0
        fi

        echo ""
        print_question "Press Enter to continue..."
        read -r
    done
}

# Function to load existing configuration
load_existing_config() {
    if [ -f "$CONFIG_FILE" ]; then
        print_status "Loading existing configuration..."
        # Source the config file to load variables
        # shellcheck source=/dev/null
        . "$CONFIG_FILE"
        return 0
    fi
    return 1
}

# Function to save configuration
save_config() {
    print_status "Saving configuration..."

    cat > "$CONFIG_FILE" << EOF
# vaydns Server Configuration
# Generated on $(date)

DOMAIN="$DOMAIN"
TUNNEL_MODE="$TUNNEL_MODE"
PRIVKEY_FILE="$PRIVKEY_FILE"
PUBKEY_FILE="$PUBKEY_FILE"
EOF

    chmod 640 "$CONFIG_FILE"
    chown root:"$VAYDNS_USER" "$CONFIG_FILE"
    print_status "Configuration saved to $CONFIG_FILE"
}

# Function to detect OS and package manager
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
    else
        print_error "Cannot detect OS"
        exit 1
    fi

    # Determine package manager
    if command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
    elif command -v yum &> /dev/null; then
        PKG_MANAGER="yum"
    elif command -v apt &> /dev/null; then
        PKG_MANAGER="apt"
    else
        print_error "Unsupported package manager"
        exit 1
    fi

    print_status "Detected OS: $OS"
    print_status "Package manager: $PKG_MANAGER"
}

# Function to check and install required tools
check_required_tools() {
    print_status "Checking required tools..."

    local required_tools=("curl" "git" "rustc" "cargo" "cmake" "pkg-config")
    local missing_tools=()

    # Check which tools are missing
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done

    # Check for iptables separately since it might need special handling
    if ! command -v "iptables" &> /dev/null; then
        missing_tools+=("iptables")
    fi

    # Check for OpenSSL development headers
    if ! pkg-config --exists openssl 2>/dev/null; then
        missing_tools+=("openssl-dev")
    fi

    if [ ${#missing_tools[@]} -gt 0 ]; then
        print_status "Installing missing tools: ${missing_tools[*]}"
        install_dependencies "${missing_tools[@]}"
    else
        print_status "All required tools are available"
    fi

    # Verify iptables installation after potential installation
    verify_iptables_installation
}

# Function to verify iptables installation and capabilities
verify_iptables_installation() {
    print_status "Verifying iptables installation..."

    if ! command -v iptables &> /dev/null; then
        print_error "iptables is not available after installation attempt"
        exit 1
    fi

    # Check if ip6tables is available (should be part of iptables package)
    if command -v ip6tables &> /dev/null; then
        print_status "Both iptables and ip6tables are available"
    else
        print_warning "ip6tables not found, IPv6 rules will be skipped"
    fi

    # Check if IPv6 is supported and configured on the system
    if [ -f /proc/net/if_inet6 ]; then
        print_status "IPv6 kernel support detected (/proc/net/if_inet6 exists)"
        # Check if IPv6 addresses are actually configured (with timeout to prevent hanging)
        local ipv6_addrs
        if command -v timeout &> /dev/null; then
            ipv6_addrs=$(timeout 2 ip -6 addr show 2>/dev/null | grep -E "inet6 [0-9a-fA-F:]+" | grep -v "::1" | grep -v "fe80:" | head -3 || true)
        else
            ipv6_addrs=$(ip -6 addr show 2>/dev/null | grep -E "inet6 [0-9a-fA-F:]+" | grep -v "::1" | grep -v "fe80:" | head -3 || true)
        fi
        if [ -n "$ipv6_addrs" ]; then
            local addr_count
            addr_count=$(echo "$ipv6_addrs" | wc -l)
            print_status "IPv6 addresses configured: $addr_count (excluding loopback and link-local)"
        else
            print_warning "IPv6 kernel support available but no IPv6 addresses configured"
        fi
    else
        print_warning "IPv6 not supported on this system (/proc/net/if_inet6 not found)"
    fi
}

# Function to install dependencies
install_dependencies() {
    local tools=("$@")
    print_status "Installing dependencies: ${tools[*]}"

    # Safety check for PKG_MANAGER
    if [[ -z "$PKG_MANAGER" ]]; then
        print_error "Package manager not detected. Make sure detect_os() is called first."
        exit 1
    fi

    case $PKG_MANAGER in
        dnf|yum)
            # For RHEL-based systems
            local packages_to_install=()

            # Always install gcc-c++ for building picoquic (CMake requires C++ compiler)
            if ! command -v g++ &> /dev/null; then
                packages_to_install+=("gcc-c++")
            fi

            for tool in "${tools[@]}"; do
                case $tool in
                    "rustc"|"cargo")
                        # Rust toolchain - install via rustup if not available
                        if ! command -v rustc &> /dev/null; then
                            print_status "Installing Rust toolchain via rustup..."
                            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
                            source "$HOME/.cargo/env" || source /root/.cargo/env
                        fi
                        ;;
                    "iptables")
                        packages_to_install+=("iptables" "iptables-services")
                        ;;
                    "openssl-dev")
                        packages_to_install+=("openssl-devel")
                        ;;
                    "cmake")
                        packages_to_install+=("cmake")
                        ;;
                    "pkg-config")
                        packages_to_install+=("pkgconfig")
                        ;;
                    *)
                        packages_to_install+=("$tool")
                        ;;
                esac
            done

            if [ ${#packages_to_install[@]} -gt 0 ]; then
                if ! $PKG_MANAGER install -y "${packages_to_install[@]}"; then
                    print_error "Failed to install packages: ${packages_to_install[*]}"
                    exit 1
                fi
            fi
            ;;
        apt)
            # For Debian-based systems
            if ! apt update; then
                print_error "Failed to update package lists"
                exit 1
            fi

            local packages_to_install=()

            # Always install g++ for building picoquic (CMake requires C++ compiler)
            if ! command -v g++ &> /dev/null; then
                packages_to_install+=("g++")
            fi

            for tool in "${tools[@]}"; do
                case $tool in
                    "rustc"|"cargo")
                        # Rust toolchain - install via rustup if not available
                        if ! command -v rustc &> /dev/null; then
                            print_status "Installing Rust toolchain via rustup..."
                            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
                            source "$HOME/.cargo/env" || source /root/.cargo/env
                        fi
                        ;;
                    "iptables")
                        packages_to_install+=("iptables")
                        if is_ufw_installed; then
                            print_status "UFW detected; skipping iptables-persistent to preserve UFW"
                        else
                            packages_to_install+=("iptables-persistent")
                        fi
                        ;;
                    "openssl-dev")
                        packages_to_install+=("libssl-dev")
                        ;;
                    "cmake")
                        packages_to_install+=("cmake")
                        ;;
                    "pkg-config")
                        packages_to_install+=("pkg-config")
                        ;;
                    *)
                        packages_to_install+=("$tool")
                        ;;
                esac
            done

            if [ ${#packages_to_install[@]} -gt 0 ]; then
                if ! apt install -y "${packages_to_install[@]}"; then
                    print_error "Failed to install packages: ${packages_to_install[*]}"
                    exit 1
                fi
            fi
            ;;
        *)
            print_error "Unsupported package manager: $PKG_MANAGER"
            exit 1
            ;;
    esac

    print_status "Dependencies installed successfully"
}

# Function to get user input
get_user_input() {
    local existing_domain=""
    local x

    if load_existing_config; then
        existing_domain="$DOMAIN"
        print_status "Found existing configuration for domain: $existing_domain"
    fi

    while true; do
        if [[ -n "$existing_domain" ]]; then
            print_question "Enter the domain for $(comp_label "$COMP") vaydns (current: $existing_domain): "
        else
            print_question "Enter the domain for $(comp_label "$COMP") vaydns (e.g., ns1.example.com): "
        fi
        read -r DOMAIN
        DOMAIN="${DOMAIN,,}"

        if [[ -z "$DOMAIN" && -n "$existing_domain" ]]; then
            DOMAIN="$existing_domain"
        fi

        if [[ -z "$DOMAIN" ]]; then
            print_error "Please enter a valid domain"
            continue
        fi
        if [[ ! "$DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
            print_error "That does not look like a valid domain"
            continue
        fi
        local clash=""
        for x in "${ALL_COMPS[@]}"; do
            [ "$x" = "$COMP" ] && continue
            [ "$(comp_domain "$x")" = "$DOMAIN" ] && clash="$x"
        done
        if [[ -n "$clash" ]]; then
            print_error "That domain is already used by the $(comp_label "$clash") vaydns instance."
            print_error "UDP 53 is split by domain, so every vaydns instance needs its own domain."
            continue
        fi
        break
    done

    TUNNEL_MODE="$COMP"
    print_status "Configuration:"
    print_status "  Instance: $COMP"
    print_status "  Domain: $DOMAIN"
}

# Function to detect architecture and get asset name
get_asset_name() {
    local arch
    arch=$(uname -m)
    local os
    os=$(uname -s | tr '[:upper:]' '[:lower:]')

    case "$os" in
        linux)
            case "$arch" in
                x86_64|amd64)
                    echo "linux-amd64"
                    return 0
                    ;;
                arm64|aarch64)
                    echo "linux-arm64"
                    return 0
                    ;;
                armv7l|armhf)
                    echo "linux-armv7"
                    return 0
                    ;;
                riscv64)
                    echo "linux-riscv64"
                    return 0
                    ;;
                mips64)
                    echo "linux-mips64"
                    return 0
                    ;;
                mips64el)
                    echo "linux-mips64le"
                    return 0
                    ;;
                mips)
                    echo "linux-mips"
                    return 0
                    ;;
                mipsel)
                    echo "linux-mipsle"
                    return 0
                    ;;
                *)
                    return 1
                    ;;
            esac
            ;;
        darwin)
            case "$arch" in
                arm64|aarch64)
                    echo "darwin-arm64"
                    return 0
                    ;;
                *)
                    return 1
                    ;;
            esac
            ;;
        *)
            return 1
            ;;
    esac
}

# Same as Slipstream: the prebuilt binary is hosted in our own GitHub
# Release (tag "assets"), uploaded next to slipstream-server-* / Xray / go*.
# Upstream (pinned tag) is only a fallback if our release copy is unreachable.
VAYDNS_REL="v0.2.8"
declare -A GITHUB_BINARY_URLS=(
    ["linux-amd64"]="https://github.com/noelrubio143/aaa/releases/download/assets/vaydns-server-linux-amd64"
)
declare -A UPSTREAM_BINARY_URLS=(
    ["linux-amd64"]="https://github.com/net2share/vaydns/releases/download/${VAYDNS_REL}/vaydns-server-linux-amd64"
)

# Function to download prebuilt binary
download_prebuilt_binary() {
    # Check if 'file' utility is available, install if missing
	if ! command -v file >/dev/null 2>&1; then
	    print_status "'file' utility not found. Installing..."

	    case "$PKG_MANAGER" in
	        apt)
	            sudo apt update && sudo apt install -y file
	            ;;
	        dnf|yum)
	            sudo "$PKG_MANAGER" install -y file
	            ;;
	        *)
	            print_error "Unsupported package manager. Please install 'file' manually."
	            exit 1
	            ;;
	    esac
	fi

    local asset_name
    if ! asset_name=$(get_asset_name); then
        print_warning "No prebuilt binary available for this architecture"
        return 1
    fi

    print_status "Attempting to download prebuilt binary for $asset_name..."

    local binary_name="vaydns-server-${asset_name}"
    local temp_binary="/tmp/${binary_name}"

    local url ok=false
    for url in "${GITHUB_BINARY_URLS[$asset_name]:-}" "${UPSTREAM_BINARY_URLS[$asset_name]:-}"; do
        [ -z "$url" ] && continue
        print_status "Trying GitHub release: $url"
        if curl -fsSL "$url" -o "$temp_binary" 2>/dev/null; then
            if file "$temp_binary" | grep -qE "(executable|ELF|Mach-O)"; then
                chmod +x "$temp_binary"
                cp "$temp_binary" "$INSTALL_DIR/vaydns-server"
                rm -f "$temp_binary"
                ok=true
                break
            fi
            print_warning "Release returned a non-binary file"
            rm -f "$temp_binary"
        else
            print_warning "Release unavailable: $url"
        fi
    done
    if [ "$ok" = true ]; then
        print_status "Successfully downloaded prebuilt binary from GitHub release"
        return 0
    fi
    return 1
}

# Function to install vaydns-server (prebuilt binary from GitHub release)
install_vaydns_server() {
    print_status "Installing vaydns-server..."

    # Both instances share the binary: stop them so the copy doesn't fail with
    # "Text file busy", and remember which ones to bring back afterwards.
    RESTART_AFTER_INSTALL=()
    local svc x
    for x in "${ALL_COMPS[@]}"; do
        svc=$(comp_service "$x")
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            print_status "Stopping $svc for binary update..."
            systemctl stop "$svc"
            RESTART_AFTER_INSTALL+=("$svc")
        fi
    done

    if download_prebuilt_binary; then
        print_status "Using prebuilt binary - skipping build dependencies"
        return 0
    fi

    print_error "Failed to download vaydns-server from GitHub release."
    print_error "Upload vaydns-server-linux-amd64 to https://github.com/noelrubio143/aaa/releases/tag/assets"
    exit 1
}

# Function to create vaydns user
create_vaydns_user() {
    print_status "Creating vaydns user..."

    if ! id "$VAYDNS_USER" &>/dev/null; then
        useradd -r -s /bin/false -d /nonexistent -c "vaydns service user" "$VAYDNS_USER"
        print_status "Created user: $VAYDNS_USER"
    else
        print_status "User $VAYDNS_USER already exists"
    fi

    # Create config directory first
    mkdir -p "$CONFIG_DIR"

    # Set ownership of config directory (shared by the ssh and xray instances)
    chown -R "$VAYDNS_USER":"$VAYDNS_USER" "$CONFIG_DIR"
    chmod 750 "$CONFIG_DIR"
}

# Function to generate the Curve25519 keypair vaydns-server authenticates with
# (vaydns has no TLS cert -- the client is given the pubkey file out of band
# and pins it, same role a cert pin would play).
generate_keys() {
    local key_prefix
    # shellcheck disable=SC2001
    key_prefix=$(echo "$DOMAIN" | sed 's/\./_/g')
    PRIVKEY_FILE="${CONFIG_DIR}/${key_prefix}_server.key"
    PUBKEY_FILE="${CONFIG_DIR}/${key_prefix}_server.pub"

    if [[ -f "$PRIVKEY_FILE" && -f "$PUBKEY_FILE" ]]; then
        print_status "Found existing keypair for domain: $DOMAIN"
        print_status "  Private key: $PRIVKEY_FILE"
        print_status "  Public key:  $PUBKEY_FILE"

        chown "$VAYDNS_USER":"$VAYDNS_USER" "$PRIVKEY_FILE" "$PUBKEY_FILE"
        chmod 600 "$PRIVKEY_FILE"
        chmod 644 "$PUBKEY_FILE"

        print_status "Using existing keypair (verified ownership and permissions)"
    else
        print_status "Generating new vaydns keypair for domain: $DOMAIN"

        if ! "${INSTALL_DIR}/vaydns-server" -gen-key \
            -privkey-file "$PRIVKEY_FILE" \
            -pubkey-file "$PUBKEY_FILE"; then
            print_error "vaydns-server -gen-key failed. Is the binary installed at ${INSTALL_DIR}/vaydns-server?"
            exit 1
        fi

        chown "$VAYDNS_USER":"$VAYDNS_USER" "$PRIVKEY_FILE" "$PUBKEY_FILE"
        chmod 600 "$PRIVKEY_FILE"
        chmod 644 "$PUBKEY_FILE"

        print_status "New keypair generated:"
        print_status "  Private key: $PRIVKEY_FILE (stays on the server)"
        print_status "  Public key:  $PUBKEY_FILE (copy this to the client/app config)"
    fi
}

# Encode a domain as DNS wire format (length-prefixed labels + root) in the
# |hex| notation iptables' string match expects.
domain_to_hex() {
    local d="${1,,}" out="" label i h c
    local IFS=.
    local -a labels
    read -ra labels <<< "$d"
    for label in "${labels[@]}"; do
        printf -v h '%02x' "${#label}"
        out+="$h"
        for ((i = 0; i < ${#label}; i++)); do
            printf -v c '%02x' "'${label:i:1}"
            out+="$c"
        done
    done
    echo "|${out}00|"
}

# Print one "<hex> <port>" line per installed instance, longest domain first
# (so a domain that is a suffix of another can never shadow it).
collect_nat_rules() {
    local c d
    for c in "${ALL_COMPS[@]}"; do
        d=$(comp_domain "$c")
        [ -n "$d" ] || continue
        echo "${#d} $(domain_to_hex "$d") $(comp_port "$c")"
    done | sort -rn | cut -d' ' -f2-
}

# Ports of the instances that are currently installed.
installed_vay_ports() {
    local c
    for c in "${ALL_COMPS[@]}"; do
        [ -f "$(comp_conf "$c")" ] && comp_port "$c"
    done
    return 0
}

# Xray inbound that vaydns-xray tunnels into (vless over plain tcp on
# localhost). The begin/end comment lines let us remove the block cleanly.
#
# Deliberately reuses the same inline "#slipvless" marker the Slipstream
# inbound uses: xray/add-vless.sh and xray/view-acc.sh already know how to
# find and append to every block carrying that exact marker, so any new
# vless account created from the menu is automatically registered on BOTH
# the Slipstream and VayDNS inbounds with no changes to those two scripts.
ensure_xray_vaydns_inbound() {
    if [ ! -f "$XRAY_JSON" ]; then
        print_error "Xray config not found at $XRAY_JSON. Install Xray first (setup1.sh / xray/ins-xray.sh)."
        return 1
    fi
    if grep -q '^#vaydns-inbound-begin$' "$XRAY_JSON"; then
        print_status "Xray vaydns inbound already present"
        return 0
    fi

    print_status "Adding Xray vaydns inbound (127.0.0.1:${XRAY_TARGET_PORT}, vless/tcp)..."
    local tmp seed uuid
    tmp=$(mktemp); seed=$(mktemp)
    uuid=$(cat /proc/sys/kernel/random/uuid)

    # Copy the existing vless accounts (the plain vless inbound only) so they also
    # work over vaydns.
    awk '/^#vless$/ {on=1; next} on && /^#& / {u=$2; e=$3; if ((getline nx) > 0) { print "#& " u " " e; print nx } next} {on=0}' "$XRAY_JSON" > "$seed"

    {
        echo '#vaydns-inbound-begin'
        cat << EOF
    {
      "listen": "127.0.0.1",
      "port": ${XRAY_TARGET_PORT},
      "protocol": "vless",
      "tag": "vaydns-vless",
      "settings": {
        "decryption": "none",
        "clients": [
          {
            "id": "${uuid}"
#slipvless
EOF
        cat "$seed"
        cat << EOF
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "none"
      }
    },
EOF
        echo '#vaydns-inbound-end'
    } > "$tmp"

    local backup="${XRAY_JSON}.bak-vaydns"
    cp "$XRAY_JSON" "$backup"
    sed -i '/"inbounds": \[/r '"$tmp" "$XRAY_JSON"
    rm -f "$tmp" "$seed"

    # Validate only if the original config was itself testable
    if command -v xray &>/dev/null && xray run -test -config "$backup" &>/dev/null; then
        if ! xray run -test -config "$XRAY_JSON" &>/dev/null; then
            print_error "Xray rejected the new config; restoring the previous one."
            cp "$backup" "$XRAY_JSON"
            return 1
        fi
    fi

    systemctl restart xray 2>/dev/null || print_warning "Could not restart xray - restart it manually"
    print_status "Xray vaydns inbound added"
    return 0
}

# Return true when the ufw command is available.
is_ufw_installed() {
    command -v ufw &> /dev/null
}

# Return true when UFW is enabled and managing the firewall.
is_ufw_active() {
    is_ufw_installed && ufw status 2>/dev/null | grep -q "Status: active"
}

# Detect the primary network interface used for default routing.
detect_network_interface() {
    local interface
    interface=$(ip route | grep default | awk '{print $5}' | head -1)
    if [[ -z "$interface" ]]; then
        interface=$(ip link show | grep -E "^[0-9]+: (eth|ens|enp)" | head -1 | cut -d':' -f2 | awk '{print $1}')
        if [[ -z "$interface" ]]; then
            interface="eth0"
            print_warning "Could not detect network interface, using eth0 as fallback" >&2
        else
            print_status "Detected network interface: $interface" >&2
        fi
    else
        print_status "Using network interface: $interface" >&2
    fi
    echo "$interface"
}

# Remove vaydns NAT redirect markers from a UFW before.rules file.
remove_ufw_nat_rules_from_file() {
    local file="$1"
    if [ -f "$file" ] && grep -q "# BEGIN vaydns" "$file"; then
        sed -i '/# BEGIN vaydns/,/# END vaydns/d' "$file"
    fi
}

# Ensure a UFW rules file has a minimal *nat table (required for DNS port redirect).
ensure_ufw_nat_section() {
    local file="$1"

    if grep -q '^\*nat' "$file"; then
        return 0
    fi

    print_status "$file has no *nat section; adding minimal NAT table..."

    if grep -q '^\*filter' "$file"; then
        awk '
            /^\*filter$/ && !done {
                print "# NAT table (added by vaydns-deploy)"
                print "*nat"
                print ":PREROUTING ACCEPT [0:0]"
                print ":POSTROUTING ACCEPT [0:0]"
                print "COMMIT"
                print ""
                done=1
            }
            { print }
        ' "$file" > "${file}.vaydns.tmp" && mv "${file}.vaydns.tmp" "$file"
    else
        {
            echo ""
            echo "# NAT table (added by vaydns-deploy)"
            echo "*nat"
            echo ":PREROUTING ACCEPT [0:0]"
            echo ":POSTROUTING ACCEPT [0:0]"
            echo "COMMIT"
        } >> "$file"
    fi
}

# Insert DNS NAT redirect rules into a UFW before.rules file.
add_ufw_nat_rules_to_file() {
    local file="$1"
    local interface="$2"

    if [ ! -f "$file" ]; then
        print_warning "$file not found, skipping NAT redirect rules"
        return 1
    fi

    ensure_ufw_nat_section "$file"
    remove_ufw_nat_rules_from_file "$file"

    local icase=""
    if iptables -m string --help 2>&1 | grep -q -- '--icase'; then icase="--icase"; fi

    local block
    block=$(mktemp)
    {
        echo "# BEGIN vaydns"
        local hex port
        while read -r hex port; do
            [ -n "$hex" ] || continue
            echo "-A PREROUTING -i ${interface} -p udp --dport 53 -m string --algo bm ${icase} --hex-string \"${hex}\" -j REDIRECT --to-ports ${port}"
        done < <(collect_nat_rules)
        echo "# END vaydns"
    } > "$block"

    if ! awk -v blockfile="$block" '
        /^\*nat$/ { in_nat=1 }
        in_nat && /^COMMIT$/ {
            while ((getline line < blockfile) > 0) print line
            in_nat=0
        }
        { print }
    ' "$file" > "${file}.vaydns.tmp"; then
        print_warning "Failed to update $file with NAT redirect rules"
        rm -f "${file}.vaydns.tmp" "$block"
        return 1
    fi
    rm -f "$block"

    mv "${file}.vaydns.tmp" "$file"

    if ! grep -q "# BEGIN vaydns" "$file"; then
        print_warning "NAT redirect rules were not written to $file"
        return 1
    fi

    print_status "NAT redirect rules added to $file"
    return 0
}

# Configure UFW port allows and NAT redirect via before.rules.
configure_ufw() {
    local interface
    interface=$(detect_network_interface)

    print_status "Configuring UFW for vaydns..."

    # UFW owns the rules here; drop our own iptables chain / boot service
    remove_iptables_rules_only

    ufw allow 53/udp
    local p
    for p in "$SSH_PORT_VAY" "$XRAY_PORT_VAY" "$OVPN_PORT_VAY" "$ALL_PORT_VAY"; do
        if installed_vay_ports | grep -qx "$p"; then
            ufw allow "$p"/udp
        else
            ufw delete allow "$p"/udp 2>/dev/null || true
        fi
    done

    local nat_v4_ok=false

    if add_ufw_nat_rules_to_file "/etc/ufw/before.rules" "$interface"; then
        nat_v4_ok=true
    else
        print_error "Failed to configure IPv4 DNS NAT redirect in UFW"
    fi

    if command -v ip6tables &> /dev/null && [ -f /proc/net/if_inet6 ]; then
        if has_ipv6_addresses; then
            if ! add_ufw_nat_rules_to_file "/etc/ufw/before6.rules" "$interface"; then
                print_warning "Failed to configure IPv6 DNS NAT redirect in UFW"
            fi
        fi
    fi

    ufw reload

    if [ "$nat_v4_ok" = true ]; then
        print_status "UFW configured successfully"
    else
        print_error "UFW port allows were added but the DNS redirect (53 -> vaydns) is not configured"
        exit 1
    fi
}

# Function to configure iptables rules
write_nat_apply_script() {
    cat > "$NAT_APPLY_SCRIPT" << 'NAT_APPLY_EOF'
#!/bin/bash
# vaydns-nat-apply: (re)build the UDP/53 redirect rules for vaydns.
# UDP/53 is split between the installed instances by the domain found inside
# the DNS query (iptables string match on the wire-format QNAME).
# Generated by vaydns-deploy - safe to run repeatedly.

CONF_DIR="/etc/vaydns"
CHAIN="VAYDNS_DNS"
RATE_CHAIN="VAYDNS_DNS_RATE"
SSH_PORT_VAY=5310
XRAY_PORT_VAY=5311
OVPN_PORT_VAY=5312
ALL_PORT_VAY=5313
RATE_LIMIT_QPS="__RATE_LIMIT_QPS__"
RATE_LIMIT_BURST="__RATE_LIMIT_BURST__"
RATE_LIMIT_NAME="vay_dns_rl"

domain_to_hex() {
    local d="${1,,}" out="" label i h c
    local IFS=.
    local -a labels
    read -ra labels <<< "$d"
    for label in "${labels[@]}"; do
        printf -v h '%02x' "${#label}"
        out+="$h"
        for ((i = 0; i < ${#label}; i++)); do
            printf -v c '%02x' "'${label:i:1}"
            out+="$c"
        done
    done
    echo "|${out}00|"
}

# "<len> <hex> <port>" per installed instance, longest domain first
rules=()
ports=()
while read -r hex port; do
    [ -n "$hex" ] || continue
    rules+=("$hex $port")
    ports+=("$port")
done < <(
    for pair in "server:$SSH_PORT_VAY" "xray:$XRAY_PORT_VAY" "ovpn:$OVPN_PORT_VAY" "all:$ALL_PORT_VAY"; do
        name="${pair%%:*}"; port="${pair##*:}"
        conf="$CONF_DIR/vaydns-${name}.conf"
        [ -f "$conf" ] || continue
        d=$(grep '^DOMAIN=' "$conf" | cut -d'"' -f2)
        [ -n "$d" ] || continue
        echo "${#d} $(domain_to_hex "$d") $port"
    done | sort -rn | cut -d' ' -f2-
)

IFACE=$(ip route | awk '/default/ {print $5; exit}')
[ -n "$IFACE" ] || IFACE="eth0"

modprobe xt_string 2>/dev/null || true
modprobe xt_hashlimit 2>/dev/null || true
ICASE=""
if iptables -m string --help 2>&1 | grep -q -- '--icase'; then ICASE="--icase"; fi

rc=0
for ipt in iptables ip6tables; do
    command -v "$ipt" &>/dev/null || continue
    if [ "$ipt" = "ip6tables" ] && [ ! -f /proc/net/if_inet6 ]; then continue; fi

    # --- cleanup: current chains + the legacy catch-all rule of older versions
    while $ipt -t nat -D PREROUTING -i "$IFACE" -p udp --dport 53 -j "$CHAIN" 2>/dev/null; do :; done
    $ipt -t nat -F "$CHAIN" 2>/dev/null
    $ipt -t nat -X "$CHAIN" 2>/dev/null
    while $ipt -t raw -D PREROUTING -i "$IFACE" -p udp --dport 53 -j "$RATE_CHAIN" 2>/dev/null; do :; done
    $ipt -t raw -F "$RATE_CHAIN" 2>/dev/null
    $ipt -t raw -X "$RATE_CHAIN" 2>/dev/null
    while $ipt -t nat -D PREROUTING -i "$IFACE" -p udp --dport 53 -j REDIRECT --to-ports "$SSH_PORT_VAY" 2>/dev/null; do :; done
    for p in "$SSH_PORT_VAY" "$XRAY_PORT_VAY" "$OVPN_PORT_VAY" "$ALL_PORT_VAY"; do
        while $ipt -D INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null; do :; done
    done

    [ "${#rules[@]}" -gt 0 ] || continue

    # --- rebuild: rate limit first, in the raw table (runs before conntrack
    # and before nat, and - unlike nat - DROP is actually allowed there).
    # Anything over RATE_LIMIT_QPS/sec per source IP (with a burst
    # allowance) never reaches the nat table's domain-match rules below,
    # so a single abusive/misbehaving client can't flood them.
    if $ipt -t raw -N "$RATE_CHAIN" 2>/dev/null; then
        if $ipt -t raw -A "$RATE_CHAIN" -p udp \
            -m hashlimit --hashlimit-above "${RATE_LIMIT_QPS}/sec" \
            --hashlimit-burst "$RATE_LIMIT_BURST" --hashlimit-mode srcip \
            --hashlimit-name "$RATE_LIMIT_NAME" --hashlimit-htable-expire 10000 \
            -j DROP 2>/dev/null; then
            $ipt -t raw -I PREROUTING -i "$IFACE" -p udp --dport 53 -j "$RATE_CHAIN" 2>/dev/null \
                || { [ "$ipt" = "iptables" ] && echo "could not hook rate-limit chain into raw PREROUTING" >&2; }
        else
            [ "$ipt" = "iptables" ] && echo "xt_hashlimit not available - rate limiting disabled on this kernel" >&2
            $ipt -t raw -X "$RATE_CHAIN" 2>/dev/null
        fi
    fi

    # --- rebuild: nat table only does the domain-match redirect (DROP is
    # not permitted in the nat table, which is why rate limiting lives above)
    if ! $ipt -t nat -N "$CHAIN" 2>/dev/null; then
        [ "$ipt" = "iptables" ] && { echo "cannot create nat chain $CHAIN" >&2; rc=1; }
        continue
    fi
    for r in "${rules[@]}"; do
        hex="${r% *}"; port="${r##* }"
        if ! $ipt -t nat -A "$CHAIN" -p udp -m string --algo bm $ICASE --hex-string "$hex" -j REDIRECT --to-ports "$port" 2>/dev/null; then
            [ "$ipt" = "iptables" ] && { echo "iptables string match not supported by this kernel (xt_string)" >&2; rc=1; }
        fi
    done
    $ipt -t nat -I PREROUTING -i "$IFACE" -p udp --dport 53 -j "$CHAIN" 2>/dev/null || rc=1
    for p in "${ports[@]}"; do
        $ipt -I INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null
    done
done
exit $rc
NAT_APPLY_EOF

    # Heredoc above is quoted (no variable expansion), so fill in the
    # configured rate-limit values after writing the file.
    sed -i "s/__RATE_LIMIT_QPS__/${RATE_LIMIT_QPS}/; s/__RATE_LIMIT_BURST__/${RATE_LIMIT_BURST}/" "$NAT_APPLY_SCRIPT"

    chmod +x "$NAT_APPLY_SCRIPT"
}

# Shared UDP/network tuning for all DNS tunnels (slipstream / vaydns / dnstt).
# Safe to run repeatedly: one file, rewritten each time.
apply_dns_tunnel_sysctl() {
    local f="/etc/sysctl.d/99-dns-tunnel.conf"
    {
        echo "# DNS tunnel tuning (slipstream / vaydns / dnstt)"
        echo "net.core.rmem_max = 8388608"
        echo "net.core.wmem_max = 8388608"
        echo "net.core.rmem_default = 1048576"
        echo "net.core.wmem_default = 1048576"
        echo "net.core.netdev_max_backlog = 5000"
        if [ -e /proc/sys/net/netfilter/nf_conntrack_max ]; then
            echo "net.netfilter.nf_conntrack_max = 262144"
        fi
    } > "$f"
    sysctl -p "$f" &>/dev/null || sysctl --system &>/dev/null || true
}

# Make sure the xt_hashlimit kernel module (used for the per-IP DNS query
# rate limit) is available. On some minimal/stripped cloud kernels it ships
# in a separate "extra modules" package instead of the base kernel image.
ensure_hashlimit_support() {
    print_status "Checking for xt_hashlimit kernel module (DNS rate limit)..."

    if modprobe xt_hashlimit 2>/dev/null; then
        print_status "xt_hashlimit is available"
        return 0
    fi

    print_warning "xt_hashlimit not available yet, attempting to install it..."

    case "$PKG_MANAGER" in
        apt)
            apt-get update -y &>/dev/null || true
            apt-get install -y "linux-modules-extra-$(uname -r)" 2>/dev/null \
                || apt-get install -y "linux-image-extra-$(uname -r)" 2>/dev/null \
                || true
            ;;
        dnf|yum)
            $PKG_MANAGER install -y kernel-modules-extra kernel-modules 2>/dev/null || true
            ;;
        *)
            print_warning "Unknown package manager, cannot auto-install the module."
            ;;
    esac

    # Some kernels need a depmod refresh before the newly-installed .ko is visible
    depmod -a 2>/dev/null || true

    if modprobe xt_hashlimit 2>/dev/null; then
        print_status "xt_hashlimit installed and loaded successfully"
        return 0
    fi

    print_warning "xt_hashlimit still not available on this kernel (common on some"
    print_warning "OpenVZ/LXC/stripped-kernel VPS). DNS query rate limiting will be"
    print_warning "skipped - the tunnel itself will still work normally."
    return 1
}

configure_iptables() {
    print_status "Configuring iptables rules for DNS redirection (split by domain)..."

    if ! command -v iptables &> /dev/null; then
        print_error "iptables command not found. Cannot configure firewall rules."
        exit 1
    fi

    ensure_hashlimit_support
    apply_dns_tunnel_sysctl

    write_nat_apply_script

    if ! "$NAT_APPLY_SCRIPT"; then
        print_error "Failed to apply the DNS redirect rules."
        print_error "Your kernel may lack the xt_string module (common on OpenVZ/LXC)."
        exit 1
    fi

    local hex port
    while read -r hex port; do
        [ -n "$hex" ] || continue
        print_status "UDP 53 with domain match $hex -> port $port"
    done < <(collect_nat_rules)

    create_iptables_restore_service
}

# Remove only our iptables chain / boot service (used when UFW manages the rules)
remove_iptables_rules_only() {
    if [ -x "$NAT_APPLY_SCRIPT" ]; then
        # Run with no instances visible so it just cleans up
        for ipt in iptables ip6tables; do
            command -v "$ipt" &>/dev/null || continue
            local iface
            iface=$(ip route | awk '/default/ {print $5; exit}')
            [ -n "$iface" ] || iface="eth0"
            while $ipt -t nat -D PREROUTING -i "$iface" -p udp --dport 53 -j VAYDNS_DNS 2>/dev/null; do :; done
            $ipt -t nat -F VAYDNS_DNS 2>/dev/null || true
            $ipt -t nat -X VAYDNS_DNS 2>/dev/null || true
            while $ipt -t raw -D PREROUTING -i "$iface" -p udp --dport 53 -j VAYDNS_DNS_RATE 2>/dev/null; do :; done
            $ipt -t raw -F VAYDNS_DNS_RATE 2>/dev/null || true
            $ipt -t raw -X VAYDNS_DNS_RATE 2>/dev/null || true
            local p
            for p in "$SSH_PORT_VAY" "$XRAY_PORT_VAY" "$OVPN_PORT_VAY" "$ALL_PORT_VAY"; do
                while $ipt -D INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null; do :; done
            done
        done
    fi
    systemctl stop vaydns-restore-iptables 2>/dev/null || true
    systemctl disable vaydns-restore-iptables 2>/dev/null || true
    rm -f "${SYSTEMD_DIR}/vaydns-restore-iptables.service" "/usr/local/bin/vaydns-restore-iptables.sh"
    systemctl daemon-reload 2>/dev/null || true
}

# Function to create a systemd service to restore iptables rules at boot
create_iptables_restore_service() {
    print_status "Creating boot service to restore the DNS redirect rules..."

    # legacy restore script from older versions
    rm -f "/usr/local/bin/vaydns-restore-iptables.sh"

    cat > "${SYSTEMD_DIR}/vaydns-restore-iptables.service" << EOF
[Unit]
Description=Restore vaydns DNS redirect rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${NAT_APPLY_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable vaydns-restore-iptables.service 2>/dev/null || print_warning "Could not enable the restore service"
    print_status "Boot restore service created"
}

# Function to configure firewall
configure_firewall() {
    print_status "Configuring firewall..."

    if is_ufw_active; then
        configure_ufw
        return 0
    fi

    if command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld; then
        print_status "Configuring active firewalld..."
        local p
        for p in "$SSH_PORT_VAY" "$XRAY_PORT_VAY" "$OVPN_PORT_VAY" "$ALL_PORT_VAY"; do
            if installed_vay_ports | grep -qx "$p"; then
                firewall-cmd --permanent --add-port="$p"/udp
            else
                firewall-cmd --permanent --remove-port="$p"/udp 2>/dev/null || true
            fi
        done
        firewall-cmd --permanent --add-port=53/udp
        firewall-cmd --reload
        print_status "Firewalld configured successfully"
    else
        print_status "No active firewall service detected"
        if is_ufw_installed; then
            print_status "UFW is installed but inactive; using plain iptables rules"
        fi
        print_status "If you have a firewall active, manually allow the vaydns ports and 53/udp"
    fi

    configure_iptables
}

# Function to detect SSH port
detect_ssh_port() {
    local ssh_port
    ssh_port=$(ss -tlnp | grep sshd | awk '{print $4}' | cut -d':' -f2 | head -1)
    if [[ -z "$ssh_port" ]]; then
        # Fallback to default SSH port
        ssh_port="22"
    fi
    echo "$ssh_port"
}

# Return true when the system has non-loopback IPv6 addresses configured.
has_ipv6_addresses() {
    if [ ! -f /proc/net/if_inet6 ]; then
        return 1
    fi

    local ipv6_addrs
    if command -v timeout &> /dev/null; then
        ipv6_addrs=$(timeout 2 ip -6 addr show 2>/dev/null | grep -E "inet6 [0-9a-fA-F:]+" | grep -v "::1" | grep -v "fe80:" || true)
    else
        ipv6_addrs=$(ip -6 addr show 2>/dev/null | grep -E "inet6 [0-9a-fA-F:]+" | grep -v "::1" | grep -v "fe80:" || true)
    fi

    [ -n "$ipv6_addrs" ]
}

# Function to install and configure Dante SOCKS proxy
# SSH mode only - no additional tunnel setup needed

# Function to create systemd service
create_systemd_service() {
    print_status "Creating systemd service..."

    local service_name="$SERVICE_NAME"
    local service_file="${SYSTEMD_DIR}/${service_name}.service"
    local target_port

    local unit_desc="vaydns DNS Tunnel Server ($(comp_label "$COMP"))"
    local unit_after="After=network.target"
    case "$COMP" in
        xray)
            target_port="$XRAY_TARGET_PORT"
            unit_after="After=network.target xray.service"
            print_status "Using Xray vless vaydns inbound port: $target_port"
            ;;
        ovpn)
            target_port="$OVPN_TARGET_PORT"
            unit_after="After=network.target openvpn-server@server.service"
            print_status "Using OpenVPN (tcp) port: $target_port"
            ;;
        all)
            target_port="$ALL_TARGET_PORT"
            unit_after="After=network.target gomux.service"
            print_status "Using gomux edge (127.0.0.1:$target_port): SSH + OpenVPN + Xray ws paths on one domain"
            if ! ss -tln 2>/dev/null | grep -q ":${target_port} "; then
                print_warning "Nothing is listening on port ${target_port} yet. Install gomux first (setup1.sh / xray/ins-gomux.sh)."
            fi
            ;;
        *)
            target_port=$(detect_ssh_port)
            print_status "Detected SSH port: $target_port"
            ;;
    esac

    # Stop service if it's running to allow reconfiguration
    if systemctl is-active --quiet "$service_name"; then
        print_status "Stopping existing $service_name service for reconfiguration..."
        systemctl stop "$service_name"
    fi

    local dns_listen_host="0.0.0.0"
    local ipv6_support=false
    local ipv6_configured=false
    local ipv6_info=""
    
    # Check IPv6 support
    if command -v ip6tables &> /dev/null; then
        ipv6_support=true
        ipv6_info="ip6tables: available"
    else
        ipv6_info="ip6tables: not available"
    fi
    
    if [ -f /proc/net/if_inet6 ]; then
        if [ "$ipv6_support" = true ]; then
            ipv6_info="$ipv6_info, /proc/net/if_inet6: exists"
        else
            ipv6_info="$ipv6_info, /proc/net/if_inet6: exists"
        fi
    else
        ipv6_info="$ipv6_info, /proc/net/if_inet6: not found"
    fi
    
    # Check if IPv6 addresses are actually configured (with timeout to prevent hanging)
    if [ "$ipv6_support" = true ] && [ -f /proc/net/if_inet6 ]; then
        local ipv6_addrs
        if command -v timeout &> /dev/null; then
            ipv6_addrs=$(timeout 2 ip -6 addr show 2>/dev/null | grep -E "inet6 [0-9a-fA-F:]+" | grep -v "::1" | grep -v "fe80:" | head -3 || true)
        else
            ipv6_addrs=$(ip -6 addr show 2>/dev/null | grep -E "inet6 [0-9a-fA-F:]+" | grep -v "::1" | grep -v "fe80:" | head -3 || true)
        fi
        if [ -n "$ipv6_addrs" ]; then
            ipv6_configured=true
            local addr_count
            addr_count=$(echo "$ipv6_addrs" | wc -l)
            ipv6_info="$ipv6_info, IPv6 addresses: $addr_count configured"
            print_status "IPv6 detection details:"
            print_status "  $ipv6_info"
            echo "$ipv6_addrs" | while read -r line; do
                print_status "    - $line"
            done
            dns_listen_host="::"
            print_status "IPv6 detected and configured, using :: for dual-stack support"
        else
            ipv6_info="$ipv6_info, IPv6 addresses: none configured"
            print_status "IPv6 detection details:"
            print_status "  $ipv6_info"
            print_status "IPv6 support available but no addresses configured, using 0.0.0.0 for IPv4 only"
        fi
    else
        print_status "IPv6 detection details:"
        print_status "  $ipv6_info"
        print_status "IPv6 not available, using 0.0.0.0 for IPv4 only"
    fi

    # vaydns-server's -udp flag takes one combined "host:port" address.
    # IPv6 "::" needs brackets in that form ("[::]:PORT"); IPv4/0.0.0.0 doesn't.
    local udp_listen_addr
    if [ "$dns_listen_host" = "::" ]; then
        udp_listen_addr="[::]:${VAYDNS_PORT}"
    else
        udp_listen_addr="${dns_listen_host}:${VAYDNS_PORT}"
    fi

    # Create systemd service file
    cat > "$service_file" << EOF
[Unit]
Description=${unit_desc}
${unit_after}
Wants=network.target
# Never give up restarting, however many times it crashes
StartLimitIntervalSec=0

[Service]
Type=simple
User=$VAYDNS_USER
Group=$VAYDNS_USER
ExecStart=${INSTALL_DIR}/vaydns-server -udp ${udp_listen_addr} -privkey-file ${PRIVKEY_FILE} -domain ${DOMAIN} -upstream 127.0.0.1:${target_port} -log-level info
Restart=always
RestartSec=1
# Make the kernel OOM-killer avoid this service
OOMScoreAdjust=-500
KillMode=mixed
TimeoutStopSec=5

# Security settings
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=/
ReadWritePaths=${CONFIG_DIR}
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
EOF

    # Reload systemd and enable service
    systemctl daemon-reload
    systemctl enable "$service_name"

    print_status "Systemd service created: $service_name"
    print_status "Service will run as user: $VAYDNS_USER"
    print_status "Service will listen on port: $VAYDNS_PORT (redirected from port 53)"
    print_status "Service will tunnel to 127.0.0.1:$target_port"
    print_status "Instance: $COMP"
}

# Function to start services
start_services() {
    print_status "Starting services..."

    systemctl restart "$SERVICE_NAME"
    print_status "$SERVICE_NAME service started"

    # bring back the other instance if we stopped it for the binary update
    local svc
    for svc in "${RESTART_AFTER_INSTALL[@]}"; do
        if [ "$svc" != "$SERVICE_NAME" ]; then
            systemctl start "$svc" 2>/dev/null && print_status "$svc service started again"
        fi
    done

    systemctl status "$SERVICE_NAME" --no-pager -l
}

# Function to print success box without [INFO] prefix
print_success_box() {
    local border_color='\033[1;32m'  # Bright green
    local text_color='\033[1;37m'    # Bright white text
    local key_color='\033[1;33m'     # Yellow for key
    local header_color='\033[1;36m'  # Cyan for headers
    local reset='\033[0m'

    echo ""
    # Top border
    echo -e "${border_color}+================================================================================${reset}"
    echo -e "${border_color}|                          SETUP COMPLETED SUCCESSFULLY!                       |${reset}"
    echo -e "${border_color}+================================================================================${reset}"
    echo ""

    # Configuration Details
    echo -e "${header_color}Configuration Details:${reset}"
    echo -e "  ${text_color}Domain: $DOMAIN${reset}"
    echo -e "  ${text_color}Instance: $(comp_label "$COMP")${reset}"
    echo -e "  ${text_color}Service user: $VAYDNS_USER${reset}"
    echo -e "  ${text_color}Listen port: $VAYDNS_PORT (UDP 53 for this domain is redirected here)${reset}"
    echo -e "  ${text_color}Server pubkey file: $PUBKEY_FILE${reset}"
    echo -e "  ${key_color}-> cat this file and put its contents into the app's VayDNS pubkey field${reset}"
    echo ""

    # Script Location
    echo -e "${text_color}Script installed at: $SCRIPT_INSTALL_PATH${reset}"
    echo ""

    # Management Commands
    echo -e "${header_color}Management Commands:${reset}"
    echo -e "  ${text_color}Run menu:           vaydns-deploy${reset}"
    echo -e "  ${text_color}Start service:      systemctl start $SERVICE_NAME${reset}"
    echo -e "  ${text_color}Stop service:       systemctl stop $SERVICE_NAME${reset}"
    echo -e "  ${text_color}Service status:     systemctl status $SERVICE_NAME${reset}"
    echo -e "  ${text_color}View logs:          journalctl -u $SERVICE_NAME -f${reset}"



    if [ "$COMP" = "xray" ]; then
        echo ""
        echo -e "${header_color}Xray vless client settings:${reset}"
        echo -e "  ${text_color}Use VayDNS (DNS Tunnel) with domain: $DOMAIN${reset}"
        echo -e "  ${text_color}Inside the tunnel: vless / tcp / security none (accounts from Menu Vless)${reset}"
    fi

    if [ "$COMP" = "ovpn" ]; then
        echo ""
        echo -e "${header_color}OpenVPN client settings:${reset}"
        echo -e "  ${text_color}Use VayDNS (DNS Tunnel) with domain: $DOMAIN${reset}"
        echo -e "  ${text_color}Inside the tunnel: OpenVPN (tcp) profile from: view-ovpn (login = SSH account)${reset}"
    fi

    if [ "$COMP" = "all" ]; then
        echo ""
        echo -e "${header_color}ALL-in-one client settings:${reset}"
        echo -e "  ${text_color}Use VayDNS (DNS Tunnel) with domain: $DOMAIN${reset}"
        echo -e "  ${text_color}Inside the tunnel (gomux, port 80): raw SSH, raw OpenVPN (tcp), or Xray over HTTP ws paths${reset}"
        echo -e "  ${text_color}(/vless /vmess /trojan-ws /xhttp-*) -- raw vless/tcp is NOT available in this mode${reset}"
    fi

    # Bottom border
    echo ""
    echo -e "${border_color}+================================================================================${reset}"
    echo ""
}

# Function to display final information
display_final_info() {
    print_success_box
}

# vaydns uses its own ports (5310/5311/5312) and shares the same domain-match
# UDP/53 redirect chain pattern as Slipstream, so -- unlike the old
# dnstt-vs-Slipstream port clash -- it does NOT need dnstt uninstalled first.
# Just warn if dnstt appears to be grabbing the whole of port 53 for itself
# (a plain, non-domain-matched REDIRECT), since that would shadow vaydns'
# domain-match rule for anything dnstt's rule also catches.
detect_dnstt() {
    if [ ! -f "/usr/local/bin/dnstt-server" ] && ! id "dnstt" &>/dev/null; then
        return 0
    fi
    echo ""
    print_warning "dnstt also appears to be installed on this VPS."
    print_warning "If dnstt holds a blanket (non domain-matched) redirect on UDP/53,"
    print_warning "it can shadow vaydns' domain-match rule. If vaydns traffic doesn't"
    print_warning "reach vaydns-server after setup, check dnstt's iptables rule order."
    echo ""
}

# Main function
main() {
    RESTART_AFTER_INSTALL=()
    set_component ssh

    # If not running from installed location (curl/GitHub), install the script first
    if [ "$0" != "$SCRIPT_INSTALL_PATH" ]; then
        print_status "Installing vaydns-deploy script..."
        install_script
        print_status "Starting vaydns server setup..."
    else
        # Running from installed location - show menu
        handle_menu
        # handle_menu returned: user picked an install/reconfigure option (COMP is set)
    fi

    # Detect OS and architecture
    detect_os

    # Xray instance needs the Xray inbound before anything else is touched
    if [ "$COMP" = "xray" ]; then
        ensure_xray_vaydns_inbound || exit 1
    fi

    # Clean up DNS conflicts before installation
    cleanup_dns_conflicts

    # Check for dnstt installation and notify user if found
    detect_dnstt

    # Get user input
    get_user_input

    # Install vaydns-server (prebuilt binary from GitHub release)
    install_vaydns_server

    # Create vaydns user
    create_vaydns_user

    # Generate keypair
    generate_keys

    # Save configuration after the keypair is generated
    save_config

    # Configure firewall and iptables (redirect rules cover every installed instance)
    configure_firewall

    # Create systemd service
    create_systemd_service

    # Start services
    start_services

    # Display final information
    display_final_info
}

# Run main function
main "$@"

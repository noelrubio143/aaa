#!/bin/bash

# soar Server Setup Script (getlantern/soar - DNS tunnel)
# Supports Fedora, Rocky, CentOS, Debian, Ubuntu
#
# Soar carries TCP connections inside DNS queries to a soar-server that is the
# authority for a delegated zone. soar-server has no fixed "upstream": the
# CLIENT names the destination and the server dials it. To make it behave like
# Slipstream / VayDNS (one tunnel -> one local service) every instance here is
# locked down so that it can only reach ONE local port:
#   * soar-server runs with -allow-private -allow-ports <that port>
#   * an iptables OUTPUT rule (owner match on the instance's own system user)
#     only lets that user open TCP to 127.0.0.1:<that port> and rejects every
#     other TCP connection, so it can't be used as an open proxy.
# Inside the tunnel the client app connects to 127.0.0.1:<port> (shown after
# install / in "Show info").
#
# The prebuilt soar-server binaries (linux amd64 + arm64) come from the
# "assets" release of noelrubio143/aaa.

# Menu (menu.sh) calls this script directly with no "Press Enter" pause
# and immediately clear()s the screen for the next redraw - so on any
# early exit() (root check, port conflict, etc.) or even after a
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
SCRIPT_URL="https://raw.githubusercontent.com/noelrubio143/aaa/main/soar/soar-deploy.sh"
SCRIPT_INSTALL_PATH="/usr/local/bin/soar-deploy"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/soar"
SYSTEMD_DIR="/etc/systemd/system"
NAT_APPLY_SCRIPT="/usr/local/bin/soar-nat-apply"
EGRESS_APPLY_SCRIPT="/usr/local/bin/soar-egress-apply"
RESTORE_SERVICE="soar-restore-iptables"
XRAY_JSON="/etc/xray/config.json"

# Where the prebuilt soar-server lives: the aaa repo "assets" release
# (soar-server-linux-amd64 / soar-server-linux-arm64 are uploaded there).
SOAR_BINARY_BASES=(
    "https://github.com/noelrubio143/aaa/releases/download/assets"
)

# Four independent soar instances share one binary (UDP/53 is split between
# them - and Slipstream / VayDNS - by the domain inside the DNS query, so each
# instance needs its own domain):
#   ssh   -> soar-server (UDP 5320) -> local SSH port
#   xray  -> soar-xray   (UDP 5321) -> Xray vless/tcp inbound 127.0.0.1:14020
#   ovpn  -> soar-ovpn   (UDP 5322) -> OpenVPN (tcp) 127.0.0.1:1194
#   all   -> soar-all    (UDP 5323) -> gomux edge 127.0.0.1:80 (SSH + OpenVPN + Xray ws paths, one domain)
ALL_COMPS=(ssh xray ovpn all)
SSH_PORT_SOAR="5320"
XRAY_PORT_SOAR="5321"
OVPN_PORT_SOAR="5322"
ALL_PORT_SOAR="5323"
ALL_TARGET_PORT="80"
OVPN_TARGET_PORT="1194"
XRAY_TARGET_PORT="14020"
COMP="ssh"

# Per-source-IP cap on incoming UDP/53 DNS queries, applied before the
# domain-match redirect so a flooding client can't hit the string match
# on every packet. Soar polls with many small queries, so this is more
# generous than the VayDNS default; it only stops a single abusive client.
RATE_LIMIT_QPS="500"      # sustained queries/sec per source IP
RATE_LIMIT_BURST="1000"   # short burst allowance per source IP

comp_service() { case "$1" in xray) echo "soar-xray" ;; ovpn) echo "soar-ovpn" ;; all) echo "soar-all" ;; *) echo "soar-server" ;; esac; }
comp_conf()    { echo "${CONFIG_DIR}/soar-$1.conf"; }
comp_user()    { echo "soar-$1"; }
comp_port()    { case "$1" in xray) echo "$XRAY_PORT_SOAR" ;; ovpn) echo "$OVPN_PORT_SOAR" ;; all) echo "$ALL_PORT_SOAR" ;; *) echo "$SSH_PORT_SOAR" ;; esac; }
comp_label()   { case "$1" in xray) echo "Xray vless" ;; ovpn) echo "OpenVPN" ;; all) echo "ALL-in-one (gomux)" ;; *) echo "SSH" ;; esac; }
comp_domain()  { local f; f=$(comp_conf "$1"); if [ -f "$f" ]; then grep '^DOMAIN=' "$f" | cut -d'"' -f2; fi; return 0; }
comp_target()  { local f; f=$(comp_conf "$1"); if [ -f "$f" ]; then grep '^TARGET_PORT=' "$f" | cut -d'"' -f2; fi; return 0; }
comp_installed() { [ -f "$(comp_conf "$1")" ]; }

# Select which instance (ssh | xray | ovpn | all) the following functions operate on.
set_component() {
    COMP="$1"
    case "$COMP" in xray|ovpn|all) ;; *) COMP="ssh" ;; esac
    SOAR_PORT=$(comp_port "$COMP")
    SERVICE_NAME=$(comp_service "$COMP")
    CONFIG_FILE=$(comp_conf "$COMP")
    SOAR_USER=$(comp_user "$COMP")
    KEY_FILE="${CONFIG_DIR}/${COMP}.key"
    PUB_FILE="${CONFIG_DIR}/${COMP}.pub"
}

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
    print_status "Installing/updating soar-deploy script..."

    local temp_script="/tmp/soar-deploy-new.sh"
    if ! curl -fLs "$SCRIPT_URL" -o "$temp_script" || [ ! -s "$temp_script" ]; then
        print_error "Could not download $SCRIPT_URL"
        rm -f "$temp_script"
        return 1
    fi
    chmod +x "$temp_script"

    if [ -f "$SCRIPT_INSTALL_PATH" ]; then
        local current_checksum new_checksum
        current_checksum=$(sha256sum "$SCRIPT_INSTALL_PATH" | cut -d' ' -f1)
        new_checksum=$(sha256sum "$temp_script" | cut -d' ' -f1)

        if [ "$current_checksum" = "$new_checksum" ]; then
            print_status "Script is already up to date"
            rm -f "$temp_script"
            return 0
        fi
        print_status "Updating existing script installation..."
    else
        print_status "Installing script for the first time..."
    fi

    cp "$temp_script" "$SCRIPT_INSTALL_PATH"
    rm -f "$temp_script"

    print_status "Script installed to $SCRIPT_INSTALL_PATH"
    print_status "You can now run 'soar-deploy' from anywhere"
}

# Function to detect OS and package manager
detect_os() {
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        OS=$NAME
    else
        print_error "Cannot detect OS"
        exit 1
    fi

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

# soar-server is a single static binary: only curl + iptables are needed.
check_required_tools() {
    local missing=()
    command -v curl &> /dev/null || missing+=("curl")
    command -v iptables &> /dev/null || missing+=("iptables")

    if [ ${#missing[@]} -eq 0 ]; then
        print_status "All required tools are available"
        return 0
    fi

    print_status "Installing missing tools: ${missing[*]}"
    case "$PKG_MANAGER" in
        apt)
            apt-get update -y
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" ca-certificates
            ;;
        dnf|yum)
            "$PKG_MANAGER" install -y "${missing[@]}" ca-certificates
            ;;
    esac

    local t
    for t in "${missing[@]}"; do
        if ! command -v "$t" &> /dev/null; then
            print_error "$t is still not available after the install attempt"
            exit 1
        fi
    done
}

# ---------------------------------------------------------------------------
# soar-server binary
# ---------------------------------------------------------------------------

get_asset_name() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "linux-amd64" ;;
        aarch64|arm64) echo "linux-arm64" ;;
        *)
            print_error "Unsupported CPU architecture: $(uname -m) (need x86_64 or aarch64)"
            return 1
            ;;
    esac
}

# Download soar-server to /usr/local/bin/soar-server (atomic replace).
# All instances share the binary: stop them so the copy can't fail with
# "Text file busy", and remember which ones to bring back afterwards.
install_soar_server() {
    print_status "Installing soar-server..."

    local asset
    asset=$(get_asset_name) || exit 1

    RESTART_AFTER_INSTALL=()
    local x svc
    for x in "${ALL_COMPS[@]}"; do
        svc=$(comp_service "$x")
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            print_status "Stopping $svc for binary update..."
            systemctl stop "$svc"
            RESTART_AFTER_INSTALL+=("$svc")
        fi
    done

    local tmp="/tmp/soar-server-${asset}" base url ok=false
    for base in "${SOAR_BINARY_BASES[@]}"; do
        url="${base}/soar-server-${asset}"
        print_status "Trying GitHub release: $url"
        rm -f "$tmp"
        if curl -fsSL "$url" -o "$tmp" 2>/dev/null && [ -s "$tmp" ] \
            && head -c 4 "$tmp" | grep -aq 'ELF'; then
            ok=true
            break
        fi
        print_warning "Release unavailable (or not a binary): $url"
    done

    if [ "$ok" != true ]; then
        rm -f "$tmp"
        print_error "Failed to download soar-server-${asset} from the GitHub release."
        print_error "Upload soar-server-${asset} to:"
        print_error "  https://github.com/noelrubio143/aaa/releases/tag/assets"
        restart_after_install
        exit 1
    fi

    chmod +x "$tmp"
    if ! "$tmp" keygen > /dev/null 2>&1; then
        rm -f "$tmp"
        print_error "The downloaded soar-server does not run on this VPS."
        restart_after_install
        exit 1
    fi

    install -m 755 "$tmp" "${INSTALL_DIR}/soar-server"
    rm -f "$tmp"
    print_status "soar-server installed to ${INSTALL_DIR}/soar-server"
}

# Bring back the instances stopped for the binary update (except the one that
# is about to be restarted by start_services anyway).
restart_after_install() {
    local svc
    for svc in "${RESTART_AFTER_INSTALL[@]}"; do
        if [ "$svc" != "${SERVICE_NAME:-}" ]; then
            systemctl start "$svc" 2>/dev/null && print_status "$svc service started again"
        fi
    done
}

# One system user per instance: that is what the iptables owner match keys on.
create_soar_user() {
    print_status "Creating $SOAR_USER user..."

    if ! id "$SOAR_USER" &>/dev/null; then
        useradd -r -s /bin/false -d /nonexistent -c "soar service user ($COMP)" "$SOAR_USER"
        print_status "Created user: $SOAR_USER"
    else
        print_status "User $SOAR_USER already exists"
    fi

    mkdir -p "$CONFIG_DIR"
    # Directory must be traversable by every instance user; the private keys
    # themselves are chmod 600 and owned by their own instance user.
    chmod 755 "$CONFIG_DIR"
}

# One Ed25519 keypair per instance. The key is kept across reconfigures so the
# public key already given to clients stays valid; delete $KEY_FILE to rotate.
generate_keys() {
    if [[ -s "$KEY_FILE" ]]; then
        print_status "Found existing server key: $KEY_FILE (keeping it)"
    else
        print_status "Generating new soar keypair for the $(comp_label "$COMP") instance..."
        local out priv
        out=$("${INSTALL_DIR}/soar-server" keygen 2>/dev/null) || out=""
        priv=$(echo "$out" | awk '/^private/ {print $2}')
        if [ -z "$priv" ]; then
            print_error "soar-server keygen failed. Is the binary installed at ${INSTALL_DIR}/soar-server?"
            exit 1
        fi
        ( umask 077; printf '%s\n' "$priv" > "$KEY_FILE" )
    fi

    chown "$SOAR_USER":"$SOAR_USER" "$KEY_FILE"
    chmod 600 "$KEY_FILE"

    local pub
    pub=$("${INSTALL_DIR}/soar-server" pubkey "$KEY_FILE" 2>/dev/null) || pub=""
    if [ -z "$pub" ]; then
        print_error "Could not derive the public key from $KEY_FILE"
        exit 1
    fi
    printf '%s\n' "$pub" > "$PUB_FILE"
    chmod 644 "$PUB_FILE"

    print_status "Private key: $KEY_FILE (stays on the server)"
    print_status "Public key:  $pub"
}

# ---------------------------------------------------------------------------
# configuration
# ---------------------------------------------------------------------------

load_existing_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        . "$CONFIG_FILE"
        return 0
    fi
    return 1
}

save_config() {
    print_status "Saving configuration..."

    cat > "$CONFIG_FILE" << EOF
# soar Server Configuration ($COMP)
# Generated on $(date)

DOMAIN="$DOMAIN"
TUNNEL_MODE="$COMP"
SOAR_PORT="$SOAR_PORT"
TARGET_PORT="$TARGET_PORT"
KEY_FILE="$KEY_FILE"
PUB_FILE="$PUB_FILE"
EOF

    chmod 644 "$CONFIG_FILE"
    print_status "Configuration saved to $CONFIG_FILE"
}

# Domains already used by the other DNS tunnels (Slipstream / VayDNS).
other_tunnel_domains() {
    local f
    for f in /etc/vaydns/*.conf /etc/slipstream-rust/*.conf; do
        [ -f "$f" ] || continue
        grep -h '^DOMAIN=' "$f" | cut -d'"' -f2
    done
    return 0
}

# Local port this instance may reach (and nothing else).
detect_ssh_port() {
    local ssh_port
    ssh_port=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | awk -F: '{print $NF}' | head -1)
    if [[ -z "$ssh_port" ]]; then
        # Fallback to default SSH port
        ssh_port="22"
    fi
    echo "$ssh_port"
}

determine_target_port() {
    case "$COMP" in
        xray)
            TARGET_PORT="$XRAY_TARGET_PORT"
            print_status "Using Xray vless soar inbound port: $TARGET_PORT"
            ;;
        ovpn)
            TARGET_PORT="$OVPN_TARGET_PORT"
            print_status "Using OpenVPN (tcp) port: $TARGET_PORT"
            ;;
        all)
            TARGET_PORT="$ALL_TARGET_PORT"
            print_status "Using gomux edge (127.0.0.1:$TARGET_PORT): SSH + OpenVPN + Xray ws paths on one domain"
            if ! ss -tln 2>/dev/null | grep -q ":${TARGET_PORT} "; then
                print_warning "Nothing is listening on port ${TARGET_PORT} yet. Install gomux first (setup1.sh / xray/ins-gomux.sh)."
            fi
            ;;
        *)
            TARGET_PORT=$(detect_ssh_port)
            print_status "Detected SSH port: $TARGET_PORT"
            ;;
    esac
}

get_user_input() {
    local existing_domain="" d x clash

    if load_existing_config; then
        existing_domain="$DOMAIN"
        print_status "Found existing configuration for domain: $existing_domain"
    fi

    while true; do
        if [[ -n "$existing_domain" ]]; then
            print_question "Enter the domain for $(comp_label "$COMP") soar (current: $existing_domain): "
        else
            print_question "Enter the domain for $(comp_label "$COMP") soar (e.g., t.example.com): "
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

        # UDP 53 is split by the domain inside the DNS query (iptables string
        # match), so a soar domain must not equal - or be a parent/child of -
        # a domain served by another soar instance, Slipstream or VayDNS.
        clash=""
        while read -r d; do
            [ -n "$d" ] || continue
            if [[ "$d" == "$DOMAIN" || "$d" == *".$DOMAIN" || "$DOMAIN" == *".$d" ]]; then
                clash="$d"
            fi
        done < <(
            other_tunnel_domains
            for x in "${ALL_COMPS[@]}"; do
                [ "$x" = "$COMP" ] && continue
                comp_domain "$x"
            done
        )
        if [[ -n "$clash" ]]; then
            print_error "That domain clashes with another tunnel domain: $clash"
            print_error "UDP 53 is split by domain, so every soar instance needs its own separate (non-overlapping) domain."
            continue
        fi
        break
    done

    determine_target_port

    print_status "Configuration:"
    print_status "  Instance: $COMP"
    print_status "  Domain: $DOMAIN"
    print_status "  Tunnel target (inside the tunnel): 127.0.0.1:$TARGET_PORT"
}

# ---------------------------------------------------------------------------
# Xray inbound that soar-xray tunnels into
# ---------------------------------------------------------------------------

# Xray inbound that soar-xray tunnels into (vless over plain tcp on
# localhost). The begin/end comment lines let us remove the block cleanly.
#
# Deliberately reuses the same inline "#slipvless" marker the Slipstream and
# VayDNS inbounds use: xray/add-vless.sh and xray/view-acc.sh already know how
# to find and append to every block carrying that exact marker, so any new
# vless account created from the menu is automatically registered on the
# Slipstream, VayDNS AND Soar inbounds.
ensure_xray_soar_inbound() {
    if [ ! -f "$XRAY_JSON" ]; then
        print_error "Xray config not found at $XRAY_JSON. Install Xray first (setup1.sh / xray/ins-xray.sh)."
        return 1
    fi
    if grep -q '^#soar-inbound-begin$' "$XRAY_JSON"; then
        print_status "Xray soar inbound already present"
        return 0
    fi

    print_status "Adding Xray soar inbound (127.0.0.1:${XRAY_TARGET_PORT}, vless/tcp)..."
    local tmp seed uuid
    tmp=$(mktemp); seed=$(mktemp)
    uuid=$(cat /proc/sys/kernel/random/uuid)

    # Copy the existing vless accounts (the plain vless inbound only) so they
    # also work over soar.
    awk '/^#vless$/ {on=1; next} on && /^#& / {u=$2; e=$3; if ((getline nx) > 0) { print "#& " u " " e; print nx } next} {on=0}' "$XRAY_JSON" > "$seed"

    {
        echo '#soar-inbound-begin'
        cat << EOF
    {
      "listen": "127.0.0.1",
      "port": ${XRAY_TARGET_PORT},
      "protocol": "vless",
      "tag": "soar-vless",
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
        echo '#soar-inbound-end'
    } > "$tmp"

    local backup="${XRAY_JSON}.bak-soar"
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
    print_status "Xray soar inbound added"
    return 0
}

# Drop the soar inbound again (uninstalling the xray instance).
remove_xray_soar_inbound() {
    [ -f "$XRAY_JSON" ] || return 0
    grep -q '^#soar-inbound-begin$' "$XRAY_JSON" || return 0
    sed -i '/^#soar-inbound-begin$/,/^#soar-inbound-end$/d' "$XRAY_JSON"
    systemctl restart xray 2>/dev/null || true
    print_status "Removed the Xray soar inbound"
}

# ---------------------------------------------------------------------------
# UDP/53 redirect (shared with Slipstream/VayDNS by domain match)
# ---------------------------------------------------------------------------

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

# UDP ports of the instances that are currently installed.
installed_soar_ports() {
    local c
    for c in "${ALL_COMPS[@]}"; do
        comp_installed "$c" && comp_port "$c"
    done
    return 0
}

any_installed() {
    local c
    for c in "${ALL_COMPS[@]}"; do
        comp_installed "$c" && return 0
    done
    return 1
}

is_ufw_installed() {
    command -v ufw &> /dev/null
}

is_ufw_active() {
    is_ufw_installed && ufw status 2>/dev/null | grep -q "Status: active"
}

detect_network_interface() {
    local interface
    interface=$(ip route | awk '/default/ {print $5; exit}')
    [ -n "$interface" ] || interface="eth0"
    echo "$interface"
}

has_ipv6_addresses() {
    ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'
}

# Remove the soar NAT redirect block from a UFW before.rules file.
remove_ufw_nat_rules_from_file() {
    local file="$1"
    if [ -f "$file" ] && grep -q "# BEGIN soar" "$file"; then
        sed -i '/# BEGIN soar/,/# END soar/d' "$file"
    fi
}

# Ensure a UFW rules file has a minimal *nat table.
ensure_ufw_nat_section() {
    local file="$1"

    if grep -q '^\*nat' "$file"; then
        return 0
    fi

    print_status "$file has no *nat section; adding minimal NAT table..."

    if grep -q '^\*filter' "$file"; then
        awk '
            /^\*filter$/ && !done {
                print "# NAT table (added by soar-deploy)"
                print "*nat"
                print ":PREROUTING ACCEPT [0:0]"
                print ":POSTROUTING ACCEPT [0:0]"
                print "COMMIT"
                print ""
                done=1
            }
            { print }
        ' "$file" > "${file}.soar.tmp" && mv "${file}.soar.tmp" "$file"
    else
        {
            echo ""
            echo "# NAT table (added by soar-deploy)"
            echo "*nat"
            echo ":PREROUTING ACCEPT [0:0]"
            echo ":POSTROUTING ACCEPT [0:0]"
            echo "COMMIT"
        } >> "$file"
    fi
}

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
        echo "# BEGIN soar"
        local hex port
        while read -r hex port; do
            [ -n "$hex" ] || continue
            echo "-A PREROUTING -i ${interface} -p udp --dport 53 -m string --algo bm ${icase} --hex-string \"${hex}\" -j REDIRECT --to-ports ${port}"
        done < <(collect_nat_rules)
        echo "# END soar"
    } > "$block"

    if ! awk -v blockfile="$block" '
        /^\*nat$/ { in_nat=1 }
        in_nat && /^COMMIT$/ {
            while ((getline line < blockfile) > 0) print line
            in_nat=0
        }
        { print }
    ' "$file" > "${file}.soar.tmp"; then
        print_warning "Failed to update $file with NAT redirect rules"
        rm -f "${file}.soar.tmp" "$block"
        return 1
    fi
    rm -f "$block"

    mv "${file}.soar.tmp" "$file"

    if ! grep -q "# BEGIN soar" "$file"; then
        print_warning "NAT redirect rules were not written to $file"
        return 1
    fi

    print_status "NAT redirect rules added to $file"
    return 0
}

configure_ufw() {
    local interface
    interface=$(detect_network_interface)

    print_status "Configuring UFW for soar..."

    # UFW owns the redirect here; drop our own iptables redirect chains
    remove_nat_chains_only

    ufw allow 53/udp
    local p
    for p in "$SSH_PORT_SOAR" "$XRAY_PORT_SOAR" "$OVPN_PORT_SOAR" "$ALL_PORT_SOAR"; do
        if installed_soar_ports | grep -qx "$p"; then
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

    if command -v ip6tables &> /dev/null && [ -f /proc/net/if_inet6 ] && has_ipv6_addresses; then
        if ! add_ufw_nat_rules_to_file "/etc/ufw/before6.rules" "$interface"; then
            print_warning "Failed to configure IPv6 DNS NAT redirect in UFW"
        fi
    fi

    ufw reload

    if [ "$nat_v4_ok" = true ]; then
        print_status "UFW configured successfully"
    else
        print_error "UFW port allows were added but the DNS redirect (53 -> soar) is not configured"
        exit 1
    fi
}

# (Re)writes /usr/local/bin/soar-nat-apply. It reads every installed instance
# from /etc/soar/soar-*.conf each time it runs, so it is also what the boot
# service calls.
write_nat_apply_script() {
    cat > "$NAT_APPLY_SCRIPT" << 'NAT_APPLY_EOF'
#!/bin/bash
# soar-nat-apply: (re)build the UDP/53 redirect rules for soar.
# UDP/53 is split between the DNS tunnels by the domain found inside the DNS
# query (iptables string match on the wire-format QNAME). Slipstream and
# VayDNS keep their own chains; this one only touches SOAR_DNS*.
# Generated by soar-deploy - safe to run repeatedly.

CONF_DIR="__CONF_DIR__"
CHAIN="SOAR_DNS"
RATE_CHAIN="SOAR_DNS_RATE"
ALL_PORTS="__ALL_PORTS__"
RATE_LIMIT_QPS="__RATE_LIMIT_QPS__"
RATE_LIMIT_BURST="__RATE_LIMIT_BURST__"
RATE_LIMIT_NAME="soar_dns_rl"

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

# "<hex> <port>" per installed instance, longest domain first
rules=()
ports=()
while read -r hex port; do
    [ -n "$hex" ] || continue
    rules+=("$hex $port")
    ports+=("$port")
done < <(
    for conf in "$CONF_DIR"/soar-*.conf; do
        [ -f "$conf" ] || continue
        d=$(grep '^DOMAIN=' "$conf" | cut -d'"' -f2)
        port=$(grep '^SOAR_PORT=' "$conf" | cut -d'"' -f2)
        [ -n "$d" ] && [ -n "$port" ] || continue
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

    # --- cleanup
    while $ipt -t nat -D PREROUTING -i "$IFACE" -p udp --dport 53 -j "$CHAIN" 2>/dev/null; do :; done
    $ipt -t nat -F "$CHAIN" 2>/dev/null
    $ipt -t nat -X "$CHAIN" 2>/dev/null
    while $ipt -t raw -D PREROUTING -i "$IFACE" -p udp --dport 53 -j "$RATE_CHAIN" 2>/dev/null; do :; done
    $ipt -t raw -F "$RATE_CHAIN" 2>/dev/null
    $ipt -t raw -X "$RATE_CHAIN" 2>/dev/null
    for p in $ALL_PORTS; do
        while $ipt -D INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null; do :; done
    done

    [ "${#rules[@]}" -gt 0 ] || continue

    # --- rebuild: rate limit first, in the raw table (runs before conntrack
    # and before nat, and - unlike nat - DROP is actually allowed there).
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

    # --- rebuild: nat table only does the domain-match redirect
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

    # The heredoc above is quoted (no expansion), so fill in the values here.
    sed -i \
        -e "s|__CONF_DIR__|${CONFIG_DIR}|" \
        -e "s|__ALL_PORTS__|${SSH_PORT_SOAR} ${XRAY_PORT_SOAR} ${OVPN_PORT_SOAR} ${ALL_PORT_SOAR}|" \
        -e "s|__RATE_LIMIT_QPS__|${RATE_LIMIT_QPS}|" \
        -e "s|__RATE_LIMIT_BURST__|${RATE_LIMIT_BURST}|" \
        "$NAT_APPLY_SCRIPT"

    chmod +x "$NAT_APPLY_SCRIPT"
}

# (Re)writes /usr/local/bin/soar-egress-apply: locks every instance's system
# user to TCP 127.0.0.1:<its target port> (OUTPUT chain SOAR_OUT, owner match).
# This is what stops soar-server (which dials whatever the client asks for)
# from being used as an open proxy. UDP is not touched (DNS replies are UDP).
write_egress_apply_script() {
    cat > "$EGRESS_APPLY_SCRIPT" << 'EGRESS_APPLY_EOF'
#!/bin/bash
# soar-egress-apply: each soar instance user may only open TCP connections to
# 127.0.0.1:<its target port>; every other outgoing TCP connection from that
# user is rejected. Generated by soar-deploy - safe to run repeatedly.

CONF_DIR="__CONF_DIR__"
CHAIN="SOAR_OUT"

# "<user> <port>" per installed instance
rules=()
for conf in "$CONF_DIR"/soar-*.conf; do
    [ -f "$conf" ] || continue
    comp=$(basename "$conf" .conf); comp="${comp#soar-}"
    port=$(grep '^TARGET_PORT=' "$conf" | cut -d'"' -f2)
    [ -n "$port" ] || continue
    rules+=("soar-${comp} ${port}")
done

modprobe xt_owner 2>/dev/null || true

rc=0
for ipt in iptables ip6tables; do
    command -v "$ipt" &>/dev/null || continue
    if [ "$ipt" = "ip6tables" ] && [ ! -f /proc/net/if_inet6 ]; then continue; fi

    # --- cleanup
    while $ipt -D OUTPUT -j "$CHAIN" 2>/dev/null; do :; done
    $ipt -F "$CHAIN" 2>/dev/null
    $ipt -X "$CHAIN" 2>/dev/null

    [ "${#rules[@]}" -gt 0 ] || continue

    lo="127.0.0.1"
    [ "$ipt" = "ip6tables" ] && lo="::1"

    $ipt -N "$CHAIN" 2>/dev/null || { [ "$ipt" = "iptables" ] && rc=1; continue; }
    for r in "${rules[@]}"; do
        u="${r% *}"; p="${r##* }"
        id -u "$u" >/dev/null 2>&1 || continue
        # Only add the REJECT if the ACCEPT could be added (e.g. xt_owner present)
        if $ipt -A "$CHAIN" -p tcp -m owner --uid-owner "$u" -d "$lo" --dport "$p" -j ACCEPT 2>/dev/null; then
            $ipt -A "$CHAIN" -p tcp -m owner --uid-owner "$u" -j REJECT --reject-with tcp-reset 2>/dev/null
        else
            [ "$ipt" = "iptables" ] && { echo "iptables owner match not supported by this kernel (xt_owner): $u is NOT restricted" >&2; rc=1; }
        fi
    done
    $ipt -I OUTPUT -j "$CHAIN" 2>/dev/null || rc=1
done
exit $rc
EGRESS_APPLY_EOF

    sed -i -e "s|__CONF_DIR__|${CONFIG_DIR}|" "$EGRESS_APPLY_SCRIPT"
    chmod +x "$EGRESS_APPLY_SCRIPT"
}

apply_egress_rules() {
    write_egress_apply_script
    if "$EGRESS_APPLY_SCRIPT"; then
        print_status "Egress lock applied (each soar user may only reach 127.0.0.1:<its port>)"
    else
        print_warning "soar-egress-apply reported a problem (xt_owner missing?) - soar may be usable as an open TCP proxy!"
    fi
}

# Remove only soar's own redirect chains (never touches Slipstream/VayDNS).
remove_nat_chains_only() {
    local ipt iface p
    iface=$(detect_network_interface)
    for ipt in iptables ip6tables; do
        command -v "$ipt" &>/dev/null || continue
        while $ipt -t nat -D PREROUTING -i "$iface" -p udp --dport 53 -j SOAR_DNS 2>/dev/null; do :; done
        $ipt -t nat -F SOAR_DNS 2>/dev/null || true
        $ipt -t nat -X SOAR_DNS 2>/dev/null || true
        while $ipt -t raw -D PREROUTING -i "$iface" -p udp --dport 53 -j SOAR_DNS_RATE 2>/dev/null; do :; done
        $ipt -t raw -F SOAR_DNS_RATE 2>/dev/null || true
        $ipt -t raw -X SOAR_DNS_RATE 2>/dev/null || true
        for p in "$SSH_PORT_SOAR" "$XRAY_PORT_SOAR" "$OVPN_PORT_SOAR" "$ALL_PORT_SOAR"; do
            while $ipt -D INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null; do :; done
        done
    done
}

# Remove the egress lock chain.
remove_egress_chain() {
    local ipt
    for ipt in iptables ip6tables; do
        command -v "$ipt" &>/dev/null || continue
        while $ipt -D OUTPUT -j SOAR_OUT 2>/dev/null; do :; done
        $ipt -F SOAR_OUT 2>/dev/null || true
        $ipt -X SOAR_OUT 2>/dev/null || true
    done
}

# Boot service that re-applies the iptables rules (they do not survive a
# reboot). $1 = "nat" also re-applies the UDP/53 redirect (only when UFW is
# not the one managing it).
create_restore_service() {
    local with_nat="$1"
    print_status "Creating boot service to restore the soar iptables rules..."

    {
        echo "[Unit]"
        echo "Description=Restore soar iptables rules"
        echo "After=network-online.target"
        echo "Wants=network-online.target"
        echo ""
        echo "[Service]"
        echo "Type=oneshot"
        echo "ExecStart=${EGRESS_APPLY_SCRIPT}"
        [ "$with_nat" = "nat" ] && echo "ExecStart=${NAT_APPLY_SCRIPT}"
        echo "RemainAfterExit=yes"
        echo ""
        echo "[Install]"
        echo "WantedBy=multi-user.target"
    } > "${SYSTEMD_DIR}/${RESTORE_SERVICE}.service"

    systemctl daemon-reload
    systemctl enable "${RESTORE_SERVICE}.service" 2>/dev/null || print_warning "Could not enable the restore service"
    print_status "Boot restore service created"
}

remove_restore_service() {
    systemctl stop "$RESTORE_SERVICE" 2>/dev/null || true
    systemctl disable "$RESTORE_SERVICE" 2>/dev/null || true
    rm -f "${SYSTEMD_DIR}/${RESTORE_SERVICE}.service"
    systemctl daemon-reload 2>/dev/null || true
}

configure_iptables() {
    print_status "Configuring iptables DNS redirect for soar..."
    write_nat_apply_script
    if "$NAT_APPLY_SCRIPT"; then
        print_status "iptables redirect applied (UDP 53 per domain -> soar ports)"
    else
        print_warning "soar-nat-apply reported a problem (xt_string / nat table missing on this kernel?)"
    fi
    apply_egress_rules
    create_restore_service nat
}

# Function to configure firewall
configure_firewall() {
    print_status "Configuring firewall..."

    if is_ufw_active; then
        configure_ufw
        apply_egress_rules
        create_restore_service egress
        return 0
    fi

    if command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld; then
        print_status "Configuring active firewalld..."
        local p
        for p in "$SSH_PORT_SOAR" "$XRAY_PORT_SOAR" "$OVPN_PORT_SOAR" "$ALL_PORT_SOAR"; do
            if installed_soar_ports | grep -qx "$p"; then
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
        print_status "If you have a firewall active, manually allow the soar ports (5320-5323/udp) and 53/udp"
    fi

    configure_iptables
}

# Shared UDP/network tuning for all DNS tunnels (slipstream / vaydns / soar).
# Safe to run repeatedly: one file, rewritten each time.
apply_dns_tunnel_sysctl() {
    local f="/etc/sysctl.d/99-dns-tunnel.conf"
    {
        echo "# DNS tunnel tuning (slipstream / vaydns / soar)"
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

# ---------------------------------------------------------------------------
# systemd service
# ---------------------------------------------------------------------------

create_systemd_service() {
    print_status "Creating systemd service..."

    local service_file="${SYSTEMD_DIR}/${SERVICE_NAME}.service"
    local unit_after="After=network.target ${RESTORE_SERVICE}.service"
    case "$COMP" in
        xray) unit_after="After=network.target ${RESTORE_SERVICE}.service xray.service" ;;
        ovpn) unit_after="After=network.target ${RESTORE_SERVICE}.service openvpn-server@server.service" ;;
        all)  unit_after="After=network.target ${RESTORE_SERVICE}.service gomux.service" ;;
    esac

    # Stop service if it's running to allow reconfiguration
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        print_status "Stopping existing $SERVICE_NAME service for reconfiguration..."
        systemctl stop "$SERVICE_NAME"
    fi

    # ":PORT" = every address, IPv4 + IPv6 (dual-stack). The redirected
    # packets arrive on the public address, so 127.0.0.1 would not work.
    # -allow-private is needed to reach 127.0.0.1; -allow-ports + the
    # iptables egress lock keep it to the one local port of this instance.
    cat > "$service_file" << EOF
[Unit]
Description=soar DNS Tunnel Server ($(comp_label "$COMP"))
${unit_after}
Wants=network.target
# Never give up restarting, however many times it crashes
StartLimitIntervalSec=0

[Service]
Type=simple
User=$SOAR_USER
Group=$SOAR_USER
ExecStart=${INSTALL_DIR}/soar-server -zone ${DOMAIN} -key-file ${KEY_FILE} -listen :${SOAR_PORT} -allow-private -allow-ports ${TARGET_PORT}
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
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"

    print_status "Systemd service created: $SERVICE_NAME"
    print_status "Service will run as user: $SOAR_USER"
    print_status "Service will listen on UDP port: $SOAR_PORT (redirected from port 53)"
    print_status "Service may only reach 127.0.0.1:$TARGET_PORT"
    print_status "Instance: $COMP"
}

start_services() {
    print_status "Starting services..."

    systemctl restart "$SERVICE_NAME"
    sleep 1
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        print_status "$SERVICE_NAME service started"
    else
        print_error "$SERVICE_NAME failed to start. Check: journalctl -u $SERVICE_NAME -e"
    fi

    # bring back the other instances if we stopped them for the binary update
    restart_after_install

    systemctl status "$SERVICE_NAME" --no-pager -l
}

# ---------------------------------------------------------------------------
# info
# ---------------------------------------------------------------------------

get_public_ip() {
    curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null \
        || curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null \
        || true
}

# One instance's details (the instance must be installed).
print_comp_info() {
    local c="$1" text_color='\033[1;37m' key_color='\033[1;33m' header_color='\033[1;36m' reset='\033[0m'
    local conf svc dom pub target port state
    conf=$(comp_conf "$c")
    svc=$(comp_service "$c")
    dom=$(grep '^DOMAIN=' "$conf" | cut -d'"' -f2)
    target=$(grep '^TARGET_PORT=' "$conf" | cut -d'"' -f2)
    port=$(grep '^SOAR_PORT=' "$conf" | cut -d'"' -f2)
    pub=$(cat "${CONFIG_DIR}/${c}.pub" 2>/dev/null)
    if systemctl is-active --quiet "$svc"; then
        state="${GREEN}RUNNING${reset}"
    else
        state="${RED}NOT RUNNING${reset}  (journalctl -u $svc -e)"
    fi

    echo -e "${header_color}$(comp_label "$c") instance:${reset}"
    echo -e "  ${text_color}Status        : ${state}${reset}"
    echo -e "  ${text_color}Domain (zone) : $dom${reset}"
    echo -e "  ${text_color}Public key    : ${key_color}$pub${reset}"
    echo -e "  ${text_color}Listen port   : UDP $port (UDP 53 for this domain is redirected here)${reset}"
    echo -e "  ${text_color}Destination inside the tunnel: 127.0.0.1:$target${reset}"
    case "$c" in
        ssh)  echo -e "  ${text_color}Client: SSH over Soar (DNS Tunnel) - login = SSH account${reset}" ;;
        xray) echo -e "  ${text_color}Client: Xray vless / tcp / security none over Soar (accounts from Menu Vless)${reset}" ;;
        ovpn) echo -e "  ${text_color}Client: OpenVPN (tcp) profile from view-ovpn over Soar (login = SSH account)${reset}" ;;
        all)  echo -e "  ${text_color}Client: gomux (port 80): raw SSH, raw OpenVPN (tcp), or Xray over HTTP ws paths${reset}" ;;
    esac
    echo -e "  ${text_color}Service       : $svc   (logs: journalctl -u $svc -f)${reset}"
    echo ""
}

print_info_box() {
    local only="$1"
    local border_color='\033[1;32m' text_color='\033[1;37m' header_color='\033[1;36m' reset='\033[0m'
    local c ip shown=0

    echo ""
    echo -e "${border_color}+================================================================================${reset}"
    echo -e "${border_color}|                                  SOAR SERVER                                 |${reset}"
    echo -e "${border_color}+================================================================================${reset}"
    echo ""

    for c in "${ALL_COMPS[@]}"; do
        [ -n "$only" ] && [ "$only" != "$c" ] && continue
        comp_installed "$c" || continue
        print_comp_info "$c"
        shown=1
    done
    if [ "$shown" -eq 0 ]; then
        print_error "soar is not installed yet. Choose option 1-4 first."
        return 1
    fi

    ip=$(get_public_ip)
    echo -e "${header_color}DNS records you need at your domain provider (for each soar domain):${reset}"
    echo -e "  ${text_color}A   record : ns-soar.<yourdomain>  ->  ${ip:-<VPS IP>}  (proxy / orange cloud OFF)${reset}"
    echo -e "  ${text_color}NS  record : <soar domain>  ->  ns-soar.<yourdomain>${reset}"
    echo ""
    echo -e "${header_color}Management Commands:${reset}"
    echo -e "  ${text_color}Run menu:        soar-deploy${reset}"
    echo -e "  ${text_color}Service status:  systemctl status soar-server soar-xray soar-ovpn soar-all${reset}"
    echo ""
    echo -e "${border_color}+================================================================================${reset}"
    echo ""
}

# ---------------------------------------------------------------------------
# menu actions
# ---------------------------------------------------------------------------

do_install() {
    RESTART_AFTER_INSTALL=()

    # Xray instance needs the Xray inbound before anything else is touched
    if [ "$COMP" = "xray" ]; then
        ensure_xray_soar_inbound || exit 1
    fi

    check_required_tools
    cleanup_dns_conflicts
    get_user_input
    install_soar_server
    create_soar_user
    generate_keys
    save_config
    apply_dns_tunnel_sysctl
    # redirect + egress lock cover every installed instance
    configure_firewall
    create_systemd_service
    start_services
    print_info_box "$COMP"
}

do_update_binary() {
    if ! any_installed; then
        print_error "soar is not installed yet. Choose option 1-4 first."
        return 1
    fi
    check_required_tools
    install_soar_server
    SERVICE_NAME=""
    restart_after_install
    local c
    for c in "${ALL_COMPS[@]}"; do
        comp_installed "$c" && systemctl status "$(comp_service "$c")" --no-pager -l 2>/dev/null | head -n 4
    done
}

uninstall_comp() {
    local c="$1" svc
    svc=$(comp_service "$c")
    print_status "Removing the $(comp_label "$c") soar instance..."

    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    rm -f "${SYSTEMD_DIR}/${svc}.service"
    systemctl daemon-reload 2>/dev/null || true

    [ "$c" = "xray" ] && remove_xray_soar_inbound
    rm -f "$(comp_conf "$c")"
    userdel "$(comp_user "$c")" 2>/dev/null || true
}

do_uninstall() {
    local c n=0 pick yn
    echo ""
    for c in "${ALL_COMPS[@]}"; do
        n=$((n + 1))
        if comp_installed "$c"; then
            echo "$n) $(comp_label "$c") - $(comp_domain "$c")"
        fi
    done
    echo "a) ALL soar instances"
    echo "0) Cancel"
    print_question "Which instance do you want to uninstall? "
    read -r pick

    local targets=()
    case "$pick" in
        1) targets=(ssh) ;;
        2) targets=(xray) ;;
        3) targets=(ovpn) ;;
        4) targets=(all) ;;
        a|A) targets=("${ALL_COMPS[@]}") ;;
        *) print_status "Cancelled."; return 0 ;;
    esac

    print_question "Really uninstall ${targets[*]}? (y/N): "
    read -r yn
    [[ "$yn" =~ ^[Yy]$ ]] || { print_status "Cancelled."; return 0; }

    for c in "${targets[@]}"; do
        comp_installed "$c" && uninstall_comp "$c"
    done

    if any_installed; then
        # other instances remain: rebuild the redirect + egress rules for them
        configure_firewall
    else
        print_status "No soar instance left - removing the shared pieces..."
        remove_nat_chains_only
        remove_egress_chain
        remove_restore_service
        rm -f "$NAT_APPLY_SCRIPT" "$EGRESS_APPLY_SCRIPT"
        if is_ufw_active; then
            local f p
            for f in /etc/ufw/before.rules /etc/ufw/before6.rules; do
                remove_ufw_nat_rules_from_file "$f"
            done
            for p in "$SSH_PORT_SOAR" "$XRAY_PORT_SOAR" "$OVPN_PORT_SOAR" "$ALL_PORT_SOAR"; do
                ufw delete allow "$p"/udp 2>/dev/null || true
            done
            ufw reload 2>/dev/null || true
        fi
        if command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld; then
            for p in "$SSH_PORT_SOAR" "$XRAY_PORT_SOAR" "$OVPN_PORT_SOAR" "$ALL_PORT_SOAR"; do
                firewall-cmd --permanent --remove-port="$p"/udp 2>/dev/null || true
            done
            firewall-cmd --reload 2>/dev/null || true
        fi
        rm -f "${INSTALL_DIR}/soar-server"
    fi

    print_question "Also delete the saved keys in ${CONFIG_DIR}? Clients will need a new key if you reinstall. (y/N): "
    read -r yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        for c in "${targets[@]}"; do
            rm -f "${CONFIG_DIR}/${c}.key" "${CONFIG_DIR}/${c}.pub"
        done
        any_installed || rmdir "$CONFIG_DIR" 2>/dev/null || true
        print_status "Keys removed"
    else
        print_status "Kept the keys in $CONFIG_DIR (reused on reinstall)"
    fi

    print_status "soar uninstall finished."
}

show_menu() {
    echo ""
    print_status "soar Server Management"
    print_status "=================================="

    echo "1) Install/Reconfigure soar - SSH (UDP ${SSH_PORT_SOAR})"
    echo "2) Install/Reconfigure soar - Xray vless/tcp (UDP ${XRAY_PORT_SOAR})"
    echo "3) Install/Reconfigure soar - OpenVPN tcp (UDP ${OVPN_PORT_SOAR})"
    echo "4) Install/Reconfigure soar - ALL-in-one: SSH + OpenVPN + Xray ws (UDP ${ALL_PORT_SOAR})"
    echo "5) Show domains / public keys / client info"
    echo "6) Update soar-server binary"
    echo "7) Uninstall soar"
    echo "0) Exit"
    echo ""
    print_question "Please select an option (0-7): "
}

# Returns after running one action (the EXIT trap then pauses before menu.sh redraws).
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
            5) print_info_box ""; return 0 ;;
            6) detect_os; do_update_binary; return 0 ;;
            7) do_uninstall; return 0 ;;
            0)
                print_status "Goodbye!"
                exit 0
                ;;
            *)
                print_error "Invalid choice. Please enter 0-7."
                ;;
        esac

        if [ -n "$pick_comp" ]; then
            set_component "$pick_comp"
            print_status "Starting $(comp_label "$pick_comp") soar installation/reconfiguration..."
            detect_os
            do_install
            return 0
        fi

        echo ""
        print_question "Press Enter to continue..."
        read -r
    done
}

main() {
    RESTART_AFTER_INSTALL=()
    set_component ssh

    # If not running from the installed location (curl/GitHub), install the
    # script first and go straight into the SSH setup.
    if [ "$0" != "$SCRIPT_INSTALL_PATH" ]; then
        print_status "Installing soar-deploy script..."
        install_script
        print_status "Starting soar server setup..."
        detect_os
        do_install
    else
        handle_menu
    fi
}

main "$@"

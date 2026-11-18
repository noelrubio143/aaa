#!/bin/bash
# Pingtunnel (ICMP tunnel) server manager for AMBER VPN menu.
# The prebuilt binary (pingtunnel_linux_amd64.zip / pingtunnel_linux_arm64.zip)
# comes from the "assets" release of noelrubio143/aaa.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
print_status()  { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

BASE_URL="https://github.com/noelrubio143/aaa/releases/download/assets"
BIN="/usr/local/bin/pingtunnel"
CONF_DIR="/etc/pingtunnel"
CONF="${CONF_DIR}/pingtunnel.conf"
SERVICE="pingtunnel"
UNIT="/etc/systemd/system/${SERVICE}.service"
SYSCTL="/etc/sysctl.d/99-pingtunnel.conf"

if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root"
    exit 1
fi

get_asset() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "pingtunnel_linux_amd64.zip" ;;
        aarch64|arm64) echo "pingtunnel_linux_arm64.zip" ;;
        *) print_error "Unsupported CPU: $(uname -m)"; return 1 ;;
    esac
}

pause() { echo ""; read -rp "Press Enter to continue... " _; }

get_ip() { curl -s4 --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'; }

load_conf() { PASS=""; [ -f "$CONF" ] && . "$CONF"; }

install_binary() {
    local asset tmp
    asset=$(get_asset) || return 1
    print_status "Downloading ${asset}..."
    command -v unzip >/dev/null 2>&1 || { apt-get update -y >/dev/null 2>&1; apt-get install -y unzip >/dev/null 2>&1; }
    tmp=$(mktemp -d)
    if ! curl -fsSL "${BASE_URL}/${asset}" -o "${tmp}/pt.zip" || [ ! -s "${tmp}/pt.zip" ]; then
        print_error "Failed to download ${BASE_URL}/${asset}"
        rm -rf "$tmp"; return 1
    fi
    unzip -o -q "${tmp}/pt.zip" -d "${tmp}/x" || { print_error "unzip failed"; rm -rf "$tmp"; return 1; }
    local f; f=$(find "${tmp}/x" -type f -name pingtunnel | head -1)
    if [ -z "$f" ] || ! head -c 4 "$f" | grep -aq 'ELF'; then
        print_error "pingtunnel binary not found in the zip (or not an ELF)"
        rm -rf "$tmp"; return 1
    fi
    systemctl stop "$SERVICE" 2>/dev/null
    install -m 755 "$f" "$BIN"
    rm -rf "$tmp"
    print_status "Installed ${BIN}"
}

write_unit() {
    cat > "$UNIT" <<UNIT_EOF
[Unit]
Description=Pingtunnel ICMP tunnel server
After=network.target

[Service]
ExecStart=${BIN} -type server -password ${PASS} -nolog
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT_EOF
    systemctl daemon-reload
}

ignore_ping() {
    # Let pingtunnel answer the ICMP echo instead of the kernel.
    echo "net.ipv4.icmp_echo_ignore_all = 1" > "$SYSCTL"
    sysctl -q -p "$SYSCTL" >/dev/null 2>&1 || echo 1 > /proc/sys/net/ipv4/icmp_echo_ignore_all
}

restore_ping() {
    rm -f "$SYSCTL"
    echo 0 > /proc/sys/net/ipv4/icmp_echo_ignore_all
}

show_info() {
    load_conf
    if [ ! -f "$CONF" ]; then print_warning "Not installed yet."; return; fi
    local ip; ip=$(get_ip)
    echo "-------------------------------------------------"
    echo " Service : $(systemctl is-active $SERVICE 2>/dev/null)"
    echo " Server  : ${ip}"
    echo " Password: ${PASS}"
    echo "-------------------------------------------------"
    echo " Client (needs root / admin), SOCKS5 mode:"
    echo "   pingtunnel -type client -l :1080 -s ${ip} -socks5 1 -password ${PASS}"
    echo " SSH account over ICMP (uses your SSH users):"
    echo "   pingtunnel -type client -l :2222 -s ${ip} -t 127.0.0.1:22 -tcp 1 -password ${PASS}"
    echo "   then: ssh -p 2222 USER@127.0.0.1"
    echo " NOTE: one shared password for everyone - no per-user accounts."
    echo "-------------------------------------------------"
    print_warning "Normal ping to this VPS no longer replies (icmp_echo_ignore_all=1)."
}

do_install() {
    install_binary || return 1
    mkdir -p "$CONF_DIR"
    load_conf
    if [ -z "$PASS" ]; then
        PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)
    fi
    echo "PASS=\"${PASS}\"" > "$CONF"
    chmod 600 "$CONF"
    write_unit
    ignore_ping
    systemctl enable "$SERVICE" >/dev/null 2>&1
    systemctl restart "$SERVICE"
    sleep 1
    if systemctl is-active --quiet "$SERVICE"; then
        print_status "Pingtunnel server is running."
    else
        print_error "Service failed to start. Check: journalctl -u ${SERVICE} -n 30"
    fi
    show_info
}

do_change_key() {
    [ -f "$CONF" ] || { print_warning "Install first."; return; }
    read -rp "New password (min 8 chars, letters/numbers only): " nk
    if ! [[ "$nk" =~ ^[A-Za-z0-9]{8,}$ ]]; then
        print_error "Password must be at least 8 characters, letters and numbers only"; return
    fi
    PASS="$nk"
    echo "PASS=\"${PASS}\"" > "$CONF"
    write_unit
    systemctl restart "$SERVICE"
    print_status "Password updated."
    show_info
}

do_uninstall() {
    read -rp "Remove pingtunnel completely? (y/N): " a
    [[ "$a" =~ ^[Yy]$ ]] || return
    systemctl disable --now "$SERVICE" 2>/dev/null
    rm -f "$UNIT" "$BIN"
    rm -rf "$CONF_DIR"
    systemctl daemon-reload
    restore_ping
    print_status "Removed. Ping replies restored."
}

while true; do
    clear
    echo -e "\e[1;34m              PINGTUNNEL (ICMP TUNNEL)              \e[0m"
    echo -e "\e[1;33m -------------------------------------------------\e[0m"
    echo " 1) Install / reinstall server"
    echo " 2) Show info / client command"
    echo " 3) Change password"
    echo " 4) Restart service"
    echo " 5) Stop service"
    echo " 6) Update binary"
    echo " 7) Uninstall"
    echo " x) Back"
    echo -e "\e[1;33m -------------------------------------------------\e[0m"
    read -rp " Select : " o
    echo ""
    case "$o" in
        1) do_install; pause ;;
        2) show_info; pause ;;
        3) do_change_key; pause ;;
        4) systemctl restart "$SERVICE" && print_status "Restarted."; pause ;;
        5) systemctl stop "$SERVICE" && print_status "Stopped."; pause ;;
        6) if install_binary; then systemctl start "$SERVICE" 2>/dev/null; print_status "Updated."; fi; pause ;;
        7) do_uninstall; pause ;;
        x|X) exit 0 ;;
        *) echo "Invalid selection"; sleep 1 ;;
    esac
done

#!/bin/bash
# L2TP/IPsec (PSK) server manager for AMBER VPN menu.
# Setup scripts (l2tp-scripts.zip) come from the "assets" release of
# noelrubio143/aaa. Underlying installer: hwdsl2/setup-ipsec-vpn.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
print_status()  { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

BASE_URL="https://github.com/noelrubio143/aaa/releases/download/assets"
ZIP_NAME="l2tp-scripts.zip"
CONF_DIR="/etc/l2tp-deploy"
CONF="${CONF_DIR}/l2tp.conf"
WORK="/opt/l2tp-scripts"

if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root"
    exit 1
fi

pause() { echo ""; read -rp "Press Enter to continue... " _; }
get_ip() { curl -s4 --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'; }
load_conf() { PSK=""; VUSER=""; VPASS=""; [ -f "$CONF" ] && . "$CONF"; }
rand() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1"; }

pick_script() {
    . /etc/os-release 2>/dev/null
    case "$ID" in
        ubuntu|debian|raspbian)
            # vpnsetup.sh is a universal wrapper; prefer the direct Ubuntu/Debian
            # script if it was bundled in the zip.
            if [ -f "${WORK}/vpnsetup_ubuntu.sh" ]; then echo "vpnsetup_ubuntu.sh"; else echo "vpnsetup.sh"; fi ;;
        centos|rhel|rocky|almalinux|ol) echo "vpnsetup_centos.sh" ;;
        alpine) echo "vpnsetup_alpine.sh" ;;
        *) echo "vpnsetup.sh" ;;
    esac
}

fetch_scripts() {
    command -v unzip >/dev/null 2>&1 || { apt-get update -y >/dev/null 2>&1; apt-get install -y unzip >/dev/null 2>&1; }
    local tmp; tmp=$(mktemp -d)
    print_status "Downloading ${ZIP_NAME}..."
    if ! curl -fsSL "${BASE_URL}/${ZIP_NAME}" -o "${tmp}/z.zip" || [ ! -s "${tmp}/z.zip" ]; then
        print_error "Failed to download ${BASE_URL}/${ZIP_NAME}"
        rm -rf "$tmp"; return 1
    fi
    rm -rf "$WORK"; mkdir -p "$WORK"
    unzip -o -q "${tmp}/z.zip" -d "$tmp/x" || { print_error "unzip failed"; rm -rf "$tmp"; return 1; }
    find "$tmp/x" -type f -name 'vpnsetup*.sh' -exec cp {} "$WORK"/ \;
    rm -rf "$tmp"
    chmod +x "$WORK"/*.sh 2>/dev/null
    [ -f "${WORK}/vpnsetup.sh" ] || { print_error "vpnsetup.sh not found in zip"; return 1; }
}

show_info() {
    load_conf
    if [ -z "$PSK" ]; then print_warning "Not installed yet."; return; fi
    local ip; ip=$(get_ip)
    echo "-------------------------------------------------"
    echo " ipsec  : $(systemctl is-active ipsec 2>/dev/null)"
    echo " xl2tpd : $(systemctl is-active xl2tpd 2>/dev/null)"
    echo " Server : ${ip}"
    echo " IPsec PSK: ${PSK}"
    echo " Username : ${VUSER}"
    echo " Password : ${VPASS}"
    echo " Ports  : UDP 500, 4500, 1701"
    echo "-------------------------------------------------"
    echo " Android: Settings > VPN > Add > L2TP/IPsec PSK"
    echo "-------------------------------------------------"
}

do_install() {
    fetch_scripts || return 1
    load_conf
    local p u w
    read -rp "IPsec PSK  [Enter = ${PSK:-random}]: " p
    read -rp "Username   [Enter = ${VUSER:-vpnuser}]: " u
    read -rp "Password   [Enter = ${VPASS:-random}]: " w
    PSK="${p:-${PSK:-$(rand 16)}}"
    VUSER="${u:-${VUSER:-vpnuser}}"
    VPASS="${w:-${VPASS:-$(rand 14)}}"

    local sh; sh=$(pick_script)
    print_status "Running ${sh} (takes a few minutes)..."
    VPN_IPSEC_PSK="$PSK" VPN_USER="$VUSER" VPN_PASSWORD="$VPASS" VPN_SKIP_IKEV2=yes \
        sh "${WORK}/${sh}"
    if [ $? -ne 0 ]; then print_error "Install failed."; return 1; fi

    mkdir -p "$CONF_DIR"
    printf 'PSK="%s"\nVUSER="%s"\nVPASS="%s"\n' "$PSK" "$VUSER" "$VPASS" > "$CONF"
    chmod 600 "$CONF"

    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow 500/udp >/dev/null; ufw allow 4500/udp >/dev/null; ufw allow 1701/udp >/dev/null
    fi
    print_status "L2TP/IPsec installed."
    show_info
}

do_restart() { systemctl restart ipsec xl2tpd 2>/dev/null && print_status "Restarted."; }
do_stop()    { systemctl stop xl2tpd ipsec 2>/dev/null && print_status "Stopped."; }
do_disable() {
    read -rp "Stop and disable L2TP/IPsec services? (y/N): " a
    [[ "$a" =~ ^[Yy]$ ]] || return
    systemctl disable --now xl2tpd ipsec 2>/dev/null
    print_status "Disabled."
}

while true; do
    clear
    echo -e "\e[1;34m              L2TP / IPSEC (PSK)              \e[0m"
    echo -e "\e[1;33m -------------------------------------------------\e[0m"
    echo " 1) Install / reinstall server"
    echo " 2) Show info"
    echo " 3) Restart service"
    echo " 4) Stop service"
    echo " 5) Update scripts from assets (re-download)"
    echo " 6) Disable services"
    echo " x) Back"
    echo -e "\e[1;33m -------------------------------------------------\e[0m"
    read -rp " Select : " o
    echo ""
    case "$o" in
        1) do_install; pause ;;
        2) show_info; pause ;;
        3) do_restart; pause ;;
        4) do_stop; pause ;;
        5) fetch_scripts && print_status "Scripts updated. Use option 1 to reinstall."; pause ;;
        6) do_disable; pause ;;
        x|X) exit 0 ;;
        *) echo "Invalid selection"; sleep 1 ;;
    esac
done

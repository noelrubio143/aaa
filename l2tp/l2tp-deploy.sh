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
        bash "${WORK}/${sh}"
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

# Plain L2TP (NO IPsec) for routers/clients that only have an "L2TP VPN client"
# form (LNS address, tunnel password, PPP user/pass). Not encrypted - the L2TP
# tunnel itself carries no encryption without IPsec. Use option 1 (reinstall)
# to go back to IPsec-only.
do_plain() {
    load_conf
    if [ -z "$PSK" ]; then print_warning "Install the server first (option 1)."; return; fi
    print_warning "Plain L2TP has NO encryption. Continue only if your device cannot use IPsec."
    read -rp "Enable plain L2TP (no IPsec)? (y/N): " a
    [[ "$a" =~ ^[Yy]$ ]] || return

    # 1) remove the rule that drops L2TP (udp/1701) not protected by IPsec
    while iptables -D INPUT -p udp --dport 1701 -m policy --dir in --pol none -j DROP 2>/dev/null; do :; done
    while iptables -D INPUT -p udp -m udp --dport 1701 -m policy --dir in --pol none -j DROP 2>/dev/null; do :; done
    # ...and from the saved copies so it stays off after a reboot
    for f in /etc/iptables.rules /etc/iptables/rules.v4 /etc/sysconfig/iptables /etc/rc.local; do
        [ -f "$f" ] && sed -i '/1701.*--pol none.*DROP/d' "$f"
    done

    # 2) accept PAP/CHAP/MS-CHAP (not only MS-CHAPv2) - many routers use "Auto"
    if [ -f /etc/ppp/options.xl2tpd ]; then
        cp -n /etc/ppp/options.xl2tpd /etc/ppp/options.xl2tpd.ipsec-bak
        sed -i 's/^+mschap-v2/#+mschap-v2/; s/^require-mschap-v2/#require-mschap-v2/' /etc/ppp/options.xl2tpd
    fi

    # 3) tunnel password = the PSK (only used if the router sends one)
    printf '* * %s\n' "$PSK" > /etc/xl2tpd/l2tp-secrets
    chmod 600 /etc/xl2tpd/l2tp-secrets

    systemctl restart xl2tpd 2>/dev/null
    local ip; ip=$(get_ip)
    echo "-------------------------------------------------"
    echo " Router (L2TP VPN client):"
    echo "  LNS address     : ${ip}"
    echo "  Tunnel password : ${PSK}   (or leave blank)"
    echo "  PPP user name   : ${VUSER}"
    echo "  PPP password    : ${VPASS}"
    echo "  Authentication  : Auto"
    echo " Ports: UDP 1701 must be open on the VPS firewall."
    echo "-------------------------------------------------"
    command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active" && ufw allow 1701/udp >/dev/null
    print_status "Plain L2TP enabled. Check logs: journalctl -u xl2tpd -e"
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
    echo " 7) Enable plain L2TP (no IPsec, for routers)"
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
        7) do_plain; pause ;;
        x|X) exit 0 ;;
        *) echo "Invalid selection"; sleep 1 ;;
    esac
done

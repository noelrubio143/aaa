#!/bin/bash
# Install aaa-main

# Colors
Red='\e[1;31m'
Green='\e[1;32m'
Yellow='\e[1;33m'
Blue='\e[1;34m'
NC='\e[0m'

# Locale
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# Ensure the script is run as root
if [ "${EUID}" -ne 0 ]; then
    echo -e "${Red}You need to run this script as root${NC}"
    sleep 5
    exit 1
fi

# Check virtualization -- OpenVZ containers are missing capabilities
# (TUN/TAP, some netfilter modules) that this stack depends on.
if [ "$(systemd-detect-virt)" == "openvz" ]; then
    echo -e "${Red}OpenVZ is not supported${NC}"
    sleep 5
    exit 1
fi

# Prevent apt/dpkg from ever popping an interactive prompt (tzdata,
# config-file conflicts, needrestart's "which services to restart?"
# checklist, etc.) - without this, installs can silently hang forever
# waiting for input that never comes, since output is redirected away.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
echo 'APT::Get::Assume-Yes "true";' > /etc/apt/apt.conf.d/90assumeyes
if [ -d /etc/needrestart ]; then
    mkdir -p /etc/needrestart/conf.d
    echo "\$nrconf{restart} = 'a';" > /etc/needrestart/conf.d/99-noninteractive.conf
fi

# Create the domain/scdomain files up front -- some of the scripts called
# later (ins-xray.sh, add-ws.sh, add-vless.sh, add-tr.sh) read or check
# for these on startup, so they need to exist (even empty) before those
# scripts run, not just by the time the domain is actually known.
mkdir -p /etc/xray /etc/v2ray
touch /etc/xray/domain /etc/v2ray/domain /etc/xray/scdomain /etc/v2ray/scdomain

# Install dependencies
echo -e "${Blue}Installing dependencies...${NC}"
apt-get update
apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" software-properties-common wget curl git dos2unix

# NOTE: this used to also build Python 2.7.18 from source here. Nothing in
# this repo actually calls python2.7 or a bare "python" (ws-dropbear /
# ws-stunnel run under python3, which is installed separately by
# sshws/insshws.sh), so it was dead weight -- and it doesn't survive newer
# toolchains: Debian 13 / Ubuntu 26 ship GCC 14+, which turns
# -Wimplicit-function-declaration into a hard error by default, and
# Python 2.7's ./configure/source predate that, so the build fails outright.
# Removed rather than patched since it wasn't being used.

# Walang domain: ang public IP ng VPS ang gagamitin at self-signed ang certificate.
# (Hindi trusted -- sa client i-on ang allowInsecure / skip-cert-verify o i-pin ang fingerprint.)
echo -e "${Blue}Getting VPS IP...${NC}"
dom="$(wget -qO- ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]')"
if ! [[ "$dom" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    dom="$(curl -s4 --max-time 10 ifconfig.me 2>/dev/null | tr -d '[:space:]')"
fi
if ! [[ "$dom" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${Red}Hindi makuha ang IP ng VPS.${NC}"
    exit 1
fi
echo -e "IP: $dom"
mkdir -p /var/lib
echo "IP=$dom" > /var/lib/ipvps.conf
echo "$dom" > /root/scdomain
echo "$dom" > /etc/xray/scdomain
echo "$dom" > /etc/xray/domain
echo "$dom" > /etc/v2ray/domain
echo "$dom" > /root/domain

# Install SSH-VPN
echo -e "${Blue}Installing SSH-VPN...${NC}"
wget -q https://gitlab.com/babayega143/aaa/-/raw/main/ssh/ssh-vpn.sh -O ssh-vpn.sh
dos2unix ssh-vpn.sh
bash ssh-vpn.sh

# Install OpenVPN (TCP on 127.0.0.1:1194 -- reached through gomux / ws-stunnel,
# same SSH accounts for login, client profile for the VPN app via `view-ovpn`)
echo -e "${Blue}Installing OpenVPN...${NC}"
wget -q https://gitlab.com/babayega143/aaa/-/raw/main/ovpn/ins-ovpn.sh -O ins-ovpn.sh
dos2unix ins-ovpn.sh
bash ins-ovpn.sh || echo -e "${Red}[!] OpenVPN install failed - the rest of the setup continues. Re-run later: bash ins-ovpn.sh${NC}"

# Install Xray
echo -e "${Blue}Installing Xray...${NC}"
wget -q https://gitlab.com/babayega143/aaa/-/raw/main/xray/ins-xray.sh -O ins-xray.sh
dos2unix ins-xray.sh
bash ins-xray.sh

# Self-signed certificate para sa IP (/etc/xray/xray.crt + xray.key)
echo -e "${Blue}Creating self-signed certificate for $dom...${NC}"
wget -q https://gitlab.com/babayega143/aaa/-/raw/main/xray/get-ssl.sh -O get-ssl.sh
dos2unix get-ssl.sh
if ! bash get-ssl.sh "$dom"; then
    echo -e "${Red}[!] Hindi nakuha ang certificate para sa $dom.${NC}"
    echo -e "${Red}    I-run ulit: bash setup1.sh${NC}"
    exit 1
fi
rm -f get-ssl.sh

# Install gomux edge layer (80/443 multiplexer)
echo -e "${Blue}Installing gomux edge layer...${NC}"
wget -q https://gitlab.com/babayega143/aaa/-/raw/main/xray/ins-gomux.sh -O ins-gomux.sh
dos2unix ins-gomux.sh
bash ins-gomux.sh

# Install SSH WebSocket
echo -e "${Blue}Installing SSH WebSocket...${NC}"
wget -q https://gitlab.com/babayega143/aaa/-/raw/main/sshws/insshws.sh
dos2unix insshws.sh
bash insshws.sh

# Slipstream is intentionally NOT installed/configured here anymore.
# ssh-vpn.sh (run above) already downloads the script straight to its
# permanent home at /usr/local/bin/slipstream-rust-deploy, so menu
# option 5 finds it there and runs its own first-time setup interactively
# ("$0 = install path" branch -> check_for_updates + handle_menu). Running
# it a second time here, unattended, used to invoke its full
# install/get_user_input flow with no TTY to answer the prompts -- at
# best a no-op re-copy, at worst a half-configured slipstream service. If
# you ever need Slipstream configured automatically during install again,
# reintroduce this as a call to `slipstream-rust-deploy` (the installed
# path) with its non-interactive flags, not by re-downloading and running
# the raw script.

# Setup environment
ln -fs /usr/share/zoneinfo/Asia/Jakarta /etc/localtime

# Additional commands
bash <(curl -Ls https://gitlab.com/babayega143/aaa/-/raw/main/swap.sh)

# FINAL VERIFICATION (BEFORE REBOOT)
echo ""
echo "════════════════════════════════════════"
echo "  FINAL SERVICE VERIFICATION"
echo "════════════════════════════════════════"
sleep 2

# Check Xray
systemctl is-active --quiet xray && echo "✓ Xray: OK" || echo "✗ Xray: FAILED"

# Check gomux edge
systemctl is-active --quiet gomux && echo "✓ gomux: OK" || echo "✗ gomux: FAILED"

# Check SSH
systemctl is-active --quiet ssh && echo "✓ SSH: OK" || echo "✗ SSH: FAILED"

# Check OpenVPN
systemctl is-active --quiet openvpn-server@server && echo "✓ OpenVPN: OK" || echo "✗ OpenVPN: FAILED"

echo ""
echo -e "${Green}✓ Installation complete!${NC}"
echo ""

# Cleanup and reboot
rm -f /root/setup1.sh /root/ssh-vpn.sh /root/ins-ovpn.sh /root/ins-xray.sh /root/ins-gomux.sh /root/insshws.sh /root/get-ssl.sh
echo "All services configured. Auto reboot in 10 seconds..."
sleep 10
reboot

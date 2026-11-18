#!/bin/bash
# Shows the OpenVPN client profile + the connection settings for the VPN app.
PROFILE=/etc/openvpn/client-tcp.ovpn
domen=$(cat /etc/xray/domain 2>/dev/null)
IP=$(curl -sS --max-time 5 ifconfig.me 2>/dev/null)
[ -z "$domen" ] && domen="$IP"

clear
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "\E[0;41;36m         OPENVPN (TCP) CONFIG          \E[0m"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"

if [ ! -f "$PROFILE" ]; then
    echo "OpenVPN is not installed yet. Run:  bash ins-ovpn.sh"
    echo ""
    read -n 1 -s -r -p "Press any key to back on menu"
    m-sshovpn
    exit 0
fi

if systemctl is-active --quiet openvpn-server@server; then
    echo -e "Service     : \033[0;32mRUNNING\033[0m (127.0.0.1:1194 tcp)"
else
    echo -e "Service     : \033[0;31mNOT RUNNING\033[0m  (journalctl -u openvpn-server@server -e)"
fi
echo -e "Login       : same username/password as the SSH account"
echo -e "Host        : $domen"
echo -e "Ports       : 80 (WS / Direct)  443 (WSS / SSL)"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "App > Server > OVPN certificate/profile: paste everything below"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
cat "$PROFILE"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "ANY payload that works for SSH works for OVPN too (Direct+Payload / SSL+Payload). Examples:"
echo -e "\nRecommended:"
echo -e "\nGET / HTTP/1.1[crlf]Host: ${domen}[crlf]Upgrade: websocket[crlf]X-Real-Host: 127.0.0.1:1194[crlf][crlf]\n"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "Payload without X-Real-Host also works (server auto-detects OpenVPN):\n\nGET / HTTP/1.1[crlf]Host: ${domen}[crlf]Upgrade: websocket[crlf][crlf]\n"
echo -e "WSS payload also works (replace isi_bug_disini with your bug host):\n\nGET wss://isi_bug_disini HTTP/1.1[crlf]Host: ${domen}[crlf]Upgrade: websocket[crlf][crlf]\n"
echo -e "Split, multi-request, CONNECT and custom-header payloads work as well (the server skips extra HTTP packets and detects OpenVPN itself)."
echo -e "No payload (Direct on 80 / SSL on 443 with SNI): works too,"
echo -e "gomux recognises the raw OpenVPN handshake."
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"

# Slipstream (DNS Tunnel) for OpenVPN - shown only when deployed (Menu > 5 > option 3)
SLIP_CONF="/etc/slipstream-rust/slipstream-rust-ovpn.conf"
if [ -f "$SLIP_CONF" ]; then
    . "$SLIP_CONF"
    echo -e "OVPN + SLIPSTREAM (DNS Tunnel)"
    echo -e "Domain      : ${DOMAIN}"
    if systemctl is-active --quiet slipstream-rust-ovpn; then
        echo -e "Service     : \033[0;32mRUNNING\033[0m (UDP 5302 -> 127.0.0.1:1194)"
    else
        echo -e "Service     : \033[0;31mNOT RUNNING\033[0m  (journalctl -u slipstream-rust-ovpn -e)"
    fi
    echo -e "Note        : pick OVPN + Slipstream (DNS Tunnel) in the client app,"
    echo -e "              use this domain as the Nameserver/Domain. Same profile + login as above."
    echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
else
    echo -e "Slipstream for OVPN not deployed. Run slipstream-rust-deploy > option 3."
    echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
fi

# VayDNS (DNS Tunnel) for OpenVPN - shown only when deployed (Menu > 6 > option 3)
VAY_CONF="/etc/vaydns/vaydns-ovpn.conf"
if [ -f "$VAY_CONF" ]; then
    vdom=$(grep '^DOMAIN=' "$VAY_CONF" | cut -d'"' -f2)
    vpubf=$(grep '^PUBKEY_FILE=' "$VAY_CONF" | cut -d'"' -f2)
    echo -e "OVPN + VAYDNS (DNS Tunnel)"
    echo -e "Domain      : ${vdom}"
    echo -e "Pubkey      : $(cat "$vpubf" 2>/dev/null)"
    if systemctl is-active --quiet vaydns-ovpn; then
        echo -e "Service     : \033[0;32mRUNNING\033[0m (UDP 5312 -> 127.0.0.1:1194)"
    else
        echo -e "Service     : \033[0;31mNOT RUNNING\033[0m  (journalctl -u vaydns-ovpn -e)"
    fi
    echo -e "Note        : pick OVPN + VayDNS (DNS Tunnel) in the client app,"
    echo -e "              use this domain + pubkey. Same profile + login as above."
    echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
else
    echo -e "VayDNS for OVPN not deployed. Run vaydns-deploy > option 3."
    echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
fi
# Soar (DNS Tunnel) for OpenVPN - shown only when deployed (Menu > 7 > option 3)
SOAR_CONF="/etc/soar/soar-ovpn.conf"
if [ -f "$SOAR_CONF" ]; then
    sdom=$(grep '^DOMAIN=' "$SOAR_CONF" | cut -d'"' -f2)
    stgt=$(grep '^TARGET_PORT=' "$SOAR_CONF" | cut -d'"' -f2)
    echo -e "OVPN + SOAR (DNS Tunnel)"
    echo -e "Domain      : ${sdom}"
    echo -e "Pubkey      : $(cat /etc/soar/ovpn.pub 2>/dev/null)"
    echo -e "Destination : 127.0.0.1:${stgt:-1194}  (inside the tunnel)"
    if systemctl is-active --quiet soar-ovpn; then
        echo -e "Service     : \033[0;32mRUNNING\033[0m (UDP 5322 -> 127.0.0.1:${stgt:-1194})"
    else
        echo -e "Service     : \033[0;31mNOT RUNNING\033[0m  (journalctl -u soar-ovpn -e)"
    fi
    echo -e "Note        : pick OVPN + Soar (DNS Tunnel) in the client app,"
    echo -e "              use this domain + pubkey. Same profile + login as above."
    echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
else
    echo -e "Soar for OVPN not deployed. Run soar-deploy > option 3."
    echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
fi
echo ""
read -n 1 -s -r -p "Press any key to back on menu"
m-sshovpn

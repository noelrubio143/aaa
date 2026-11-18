#!/bin/bash
MYIP=$(wget -qO- ipv4.icanhazip.com);
echo "Checking VPS"
clear
domen=$(cat /etc/xray/domain)
portsshws=80
wsssl=443

echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "\E[0;41;36m          SENSI SSH Account            \E[0m"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
read -p "Username : " Login
read -p "Password : " Pass
read -p "Expired (hari): " masaaktif

IP=$(curl -sS ifconfig.me);
opensh="22,200,500,53,666,40000,51443,58080"
ssl=443

sleep 1
clear
useradd -e `date -d "$masaaktif days" +"%Y-%m-%d"` -s /bin/false -M $Login
exp="$(chage -l $Login | grep "Account expires" | awk -F": " '{print $2}')"
echo -e "$Pass\n$Pass\n"|passwd $Login &> /dev/null
# save the password so the account can be viewed again later (root only)
touch /etc/ssh-accounts; chmod 600 /etc/ssh-accounts
( umask 077; awk -F: -v u="$Login" '$1 != u' /etc/ssh-accounts > /etc/ssh-accounts.tmp ) && mv /etc/ssh-accounts.tmp /etc/ssh-accounts
echo "${Login}:${Pass}" >> /etc/ssh-accounts
chmod 600 /etc/ssh-accounts
PID=`ps -ef |grep -v grep | grep sshws |awk '{print $2}'`

if [[ ! -z "${PID}" ]]; then
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "\E[0;41;36m           SENSI SSH Account            \E[0m"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "Username    : $Login"
echo -e "Password    : $Pass"
echo -e "Expired On  : $exp"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "IP          : $IP"
echo -e "Host        : $domen"
echo -e "OpenSSH     : $opensh"
echo -e "SSH WS      : $portsshws"
echo -e "SSH SSL WS  : $wsssl"
echo -e "SSL/TLS     : $ssl"
echo -e "UDPGW       : 7100-7900"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "
GET / HTTP/1.1[crlf]Host: ${domen}[crlf]Upgrade: websocket[crlf]X-Real-Host: 127.0.0.1:1194[crlf][crlf]
"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "Payload WSS"
echo -e "
GET wss://isi_bug_disini HTTP/1.1[crlf]Host: ${domen}[crlf]Upgrade: websocket[crlf][crlf]
"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "Payload WS"
echo -e "
GET / HTTP/1.1[crlf]Host: $domen[crlf]Upgrade: websocket[crlf][crlf]
"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
else

echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "\E[0;41;36m           SENSI SSH Account            \E[0m"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "Username    : $Login"
echo -e "Password    : $Pass"
echo -e "Expired On  : $exp"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "IP          : $IP"
echo -e "Host        : $domen"
echo -e "OpenSSH     : $opensh"
echo -e "SSH WS      : $portsshws"
echo -e "SSH SSL WS  : $wsssl"
echo -e "SSL/TLS     : $ssl"
echo -e "UDPGW       : 7100-7900"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "
GET / HTTP/1.1[crlf]Host: ${domen}[crlf]Upgrade: websocket[crlf]X-Real-Host: 127.0.0.1:1194[crlf][crlf]
"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "Expired On  : $exp"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "Payload WSS"
echo -e "
GET wss://isi_bug_disini HTTP/1.1[crlf]Host: ${domen}[crlf]Upgrade: websocket[crlf][crlf]
"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "Payload WS"
echo -e "
GET / HTTP/1.1[crlf]Host: $domen[crlf]Upgrade: websocket[crlf][crlf]
"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
fi

# OpenVPN (TCP) - shown only when the OpenVPN server is installed (ovpn/ins-ovpn.sh).
# Same username/password as SSH. Paste the profile below in the app (server > OVPN certificate).
if [ -f /etc/openvpn/client-tcp.ovpn ]; then
    echo -e "\E[0;41;36m          CONFIG OPENVPN (TCP)          \E[0m"
    echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    echo -e "Username    : $Login"
    echo -e "Password    : $Pass"
    echo -e "Host        : $domen"
    echo -e "Port WS     : 80"
    echo -e "Port WSS/SSL: 443"
    echo -e "Payload: ANY payload that works for SSH works for OVPN too. Examples:"
    echo -e "  1) WS + X-Real-Host:"
    echo -e "     GET / HTTP/1.1[crlf]Host: ${domen}[crlf]Upgrade: websocket[crlf]X-Real-Host: 127.0.0.1:1194[crlf][crlf]"
    echo -e "  2) WS (server auto-detects OpenVPN):"
    echo -e "     GET / HTTP/1.1[crlf]Host: ${domen}[crlf]Upgrade: websocket[crlf][crlf]"
    echo -e "  3) WSS (replace isi_bug_disini with your bug host):"
    echo -e "     GET wss://isi_bug_disini HTTP/1.1[crlf]Host: ${domen}[crlf]Upgrade: websocket[crlf][crlf]"
    echo -e "  4) No payload: Direct 80 / SSL 443 (SNI)"
    echo -e "  (split / multi-request / CONNECT / custom-header payloads also work)"
    echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    echo -e "Profile (paste in app):"
    cat /etc/openvpn/client-tcp.ovpn
    echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"

    # --- OpenVPN over DNS tunnel (NS shown here, same as SSH/Xray) ---
    # Slipstream for OVPN (Menu > 5 > option 3)
    OV_SLIP_CONF="/etc/slipstream-rust/slipstream-rust-ovpn.conf"
    if [ -f "$OV_SLIP_CONF" ]; then
        odom=$( . "$OV_SLIP_CONF" 2>/dev/null; echo "$DOMAIN" )
        echo -e "\E[0;41;36m     CONFIG OVPN + SLIPSTREAM (DNS)     \E[0m"
        echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
        echo -e "NS Domain   : ${odom:-$domen}"
        echo -e "Username    : $Login"
        echo -e "Password    : $Pass"
        echo -e "Note        : pick OVPN + Slipstream (DNS Tunnel) in the client app,"
        echo -e "              use this domain as the NS/Domain. Same profile + login as above."
        echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    fi
    # VayDNS for OVPN (Menu > 6 > option 3)
    OV_VAY_CONF="/etc/vaydns/vaydns-ovpn.conf"
    if [ -f "$OV_VAY_CONF" ]; then
        ovdom=$(grep '^DOMAIN=' "$OV_VAY_CONF" | cut -d'"' -f2)
        ovpubf=$(grep '^PUBKEY_FILE=' "$OV_VAY_CONF" | cut -d'"' -f2)
        echo -e "\E[0;41;36m      CONFIG OVPN + VAYDNS (DNS)        \E[0m"
        echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
        echo -e "NS Domain   : ${ovdom:-$domen}"
        echo -e "Pubkey      : $(cat "$ovpubf" 2>/dev/null)"
        echo -e "Username    : $Login"
        echo -e "Password    : $Pass"
        echo -e "Note        : pick OVPN + VayDNS (DNS Tunnel) in the client app,"
        echo -e "              use this NS/Domain + the pubkey above. Same profile + login as above."
        echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    fi
    # Soar for OVPN (Menu > 7 > option 3)
    OV_SOAR_CONF="/etc/soar/soar-ovpn.conf"
    if [ -f "$OV_SOAR_CONF" ]; then
        osdom=$(grep '^DOMAIN=' "$OV_SOAR_CONF" | cut -d'"' -f2)
        ostgt=$(grep '^TARGET_PORT=' "$OV_SOAR_CONF" | cut -d'"' -f2)
        echo -e "\E[0;41;36m       CONFIG OVPN + SOAR (DNS)         \E[0m"
        echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
        echo -e "NS Domain   : ${osdom:-$domen}"
        echo -e "Pubkey      : $(cat /etc/soar/ovpn.pub 2>/dev/null)"
        echo -e "Destination : 127.0.0.1:${ostgt:-1194}  (inside the tunnel)"
        echo -e "Username    : $Login"
        echo -e "Password    : $Pass"
        echo -e "Note        : pick OVPN + Soar (DNS Tunnel) in the client app,"
        echo -e "              use this NS/Domain + the pubkey above. Same profile + login as above."
        echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    fi
fi

# Slipstream (DNS Tunnel) - same VPS/domain as above. Only shown when the
# Slipstream server has actually been deployed (Menu > option 5). Slipstream
# is SSH-only now (no SOCKS/Shadowsocks mode), so all it needs from the
# deploy config is the domain.
SLIPSTREAM_CONF="/etc/slipstream-rust/slipstream-rust-server.conf"
if [ -f "$SLIPSTREAM_CONF" ]; then
    . "$SLIPSTREAM_CONF"
    echo -e "\E[0;41;36m         CONFIG SLIPSTREAM (DNS)        \E[0m"
    echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    echo -e "Domain      : ${DOMAIN:-$domen}"
    echo -e "Note        : pick Slipstream (DNS Tunnel) in the client app"
    echo -e "              and use this domain as the Nameserver/Domain."
    echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
fi

# VayDNS (DNS Tunnel) - shown only when it has been deployed (Menu > 6)
VAY_CONF="/etc/vaydns/vaydns-server.conf"
if [ -f "$VAY_CONF" ]; then
    vdom=$(grep '^DOMAIN=' "$VAY_CONF" | cut -d'"' -f2)
    vpubf=$(grep '^PUBKEY_FILE=' "$VAY_CONF" | cut -d'"' -f2)
    echo -e "\E[0;41;36m          CONFIG VAYDNS (DNS)           \E[0m"
    echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    echo -e "Domain      : ${vdom:-$domen}"
    echo -e "Pubkey      : $(cat "$vpubf" 2>/dev/null)"
    echo -e "Note        : pick VayDNS (DNS Tunnel) in the client app,"
    echo -e "              use this domain as the Nameserver/Domain + the pubkey above."
    echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
fi

# Soar (DNS Tunnel) for SSH - shown only when it has been deployed (Menu > 7)
SOAR_CONF="/etc/soar/soar-ssh.conf"
if [ -f "$SOAR_CONF" ]; then
    sdom=$(grep '^DOMAIN=' "$SOAR_CONF" | cut -d'"' -f2)
    stgt=$(grep '^TARGET_PORT=' "$SOAR_CONF" | cut -d'"' -f2)
    echo -e "\E[0;41;36m           CONFIG SOAR (DNS)            \E[0m"
    echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    echo -e "Domain      : ${sdom:-$domen}"
    echo -e "Pubkey      : $(cat /etc/soar/ssh.pub 2>/dev/null)"
    echo -e "Destination : 127.0.0.1:${stgt:-22}  (inside the tunnel)"
    echo -e "Note        : pick Soar (DNS Tunnel) in the client app,"
    echo -e "              use this domain as the Nameserver/Domain + the pubkey above."
    echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
fi

echo ""
read -n 1 -s -r -p "Press any key to back on menu"

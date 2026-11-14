#!/bin/bash
###############################################################################
# OpenVPN (TCP) server for aaa-main -- matches the VPN app's OVPN profile.
#
#   - listens ONLY on 127.0.0.1:1194 (tcp). It is reached through the edge:
#       :80/:443  raw OpenVPN (Direct / SSL mode)  -> gomux       -> 1194
#       :80/:443  HTTP payload + "X-Real-Host: 127.0.0.1:1194"
#                                                   -> ws-stunnel  -> 1194
#   - login = the same Linux/SSH accounts (usernew / hapus / member), checked
#     through PAM, so expiry dates work like they do for SSH.
#   - own CA + server cert (openssl). The client profile is written to
#     /etc/openvpn/client-tcp.ovpn; paste it in the app's server entry
#     (OVPN certificate field). View it any time with:  view-ovpn
###############################################################################

set -e
export DEBIAN_FRONTEND=noninteractive

red='\033[0;31m'; green='\033[0;32m'; blue='\033[0;34m'; NC='\033[0m'
echo -e "${blue}[*] Installing OpenVPN (TCP, via 127.0.0.1:1194)${NC}"

OVPN_PORT=1194
OVPN_NET=10.8.0.0
OVPN_MASK=255.255.255.0
CIPHER=AES-128-GCM
AUTH=SHA256
DIR=/etc/openvpn/server
PKI=/etc/openvpn/aaa-pki

apt-get update -y
apt-get install -y openvpn openssl iptables iptables-persistent netfilter-persistent curl

PLUGIN=""
for p in /usr/lib/openvpn/openvpn-plugin-auth-pam.so \
         /usr/lib/x86_64-linux-gnu/openvpn/plugins/openvpn-plugin-auth-pam.so \
         /usr/lib/aarch64-linux-gnu/openvpn/plugins/openvpn-plugin-auth-pam.so \
         /usr/lib/openvpn/plugins/openvpn-plugin-auth-pam.so; do
    if [ -f "$p" ]; then PLUGIN="$p"; break; fi
done
if [ -z "$PLUGIN" ]; then
    echo -e "${red}[-] openvpn-plugin-auth-pam.so not found - OpenVPN package incomplete.${NC}"
    exit 1
fi

# ---- OpenVPN 2.4 has no data-ciphers (it is called ncp-ciphers there) ----
VER=$(openvpn --version | head -1 | awk '{print $2}')
MAJ=${VER%%.*}; MIN=${VER#*.}; MIN=${MIN%%.*}
if [ "$MAJ" -gt 2 ] || { [ "$MAJ" -eq 2 ] && [ "$MIN" -ge 5 ]; }; then
    NCP="data-ciphers AES-128-GCM:AES-256-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-128-GCM"
else
    NCP="ncp-ciphers AES-128-GCM:AES-256-GCM"
fi

# ---- PKI: own CA + server certificate (kept if it already exists) ----
mkdir -p "$PKI" "$DIR"
chmod 700 "$PKI"
if [ ! -f "$PKI/ca.crt" ] || [ ! -f "$PKI/server.crt" ] || [ ! -f "$PKI/server.key" ]; then
    echo -e "${blue}[*] Generating CA and server certificate${NC}"
    openssl genrsa -out "$PKI/ca.key" 2048 2>/dev/null
    openssl req -x509 -new -nodes -key "$PKI/ca.key" -sha256 -days 3650 \
        -subj "/CN=AMBERVPN-CA" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -out "$PKI/ca.crt"
    openssl genrsa -out "$PKI/server.key" 2048 2>/dev/null
    openssl req -new -key "$PKI/server.key" -subj "/CN=AMBERVPN-SERVER" -out "$PKI/server.csr"
    printf '%s\n' "basicConstraints=CA:FALSE" \
        "keyUsage=digitalSignature,keyEncipherment" \
        "extendedKeyUsage=serverAuth" > "$PKI/server.ext"
    openssl x509 -req -in "$PKI/server.csr" -CA "$PKI/ca.crt" -CAkey "$PKI/ca.key" \
        -CAcreateserial -sha256 -days 3650 -extfile "$PKI/server.ext" -out "$PKI/server.crt" 2>/dev/null
    rm -f "$PKI/server.csr" "$PKI/server.ext" "$PKI/ca.srl"
    chmod 600 "$PKI"/*.key
fi
cp "$PKI/ca.crt" "$PKI/server.crt" "$PKI/server.key" "$DIR/"
chmod 644 "$DIR/ca.crt" "$DIR/server.crt"
chmod 600 "$DIR/server.key"

# ---- PAM service: same accounts as SSH (expiry honoured) ----
printf '%s\n' "auth     required   pam_unix.so" \
              "account  required   pam_unix.so" > /etc/pam.d/openvpn

# ---- server.conf ----
{
    echo "local 127.0.0.1"
    echo "port $OVPN_PORT"
    echo "proto tcp"
    echo "dev tun"
    echo ""
    echo "ca ca.crt"
    echo "cert server.crt"
    echo "key server.key"
    echo "dh none"
    echo ""
    echo "topology subnet"
    echo "server $OVPN_NET $OVPN_MASK"
    echo 'push "redirect-gateway def1 bypass-dhcp"'
    echo 'push "dhcp-option DNS 1.1.1.1"'
    echo 'push "dhcp-option DNS 8.8.8.8"'
    echo ""
    echo "# login with the SSH accounts (no client certificate)"
    echo "plugin $PLUGIN openvpn"
    echo "verify-client-cert none"
    echo "username-as-common-name"
    echo "duplicate-cn"
    echo ""
    echo "cipher $CIPHER"
    echo "$NCP"
    echo "auth $AUTH"
    echo ""
    echo "keepalive 10 120"
    echo "reneg-sec 0"
    echo "persist-key"
    echo "persist-tun"
    echo "user nobody"
    echo "group nogroup"
    echo "verb 3"
    echo "log-append /var/log/openvpn-aaa.log"
} > "$DIR/server.conf"
touch /var/log/openvpn-aaa.log

# older unit files cap processes at 10, which stops the PAM plugin from forking
mkdir -p /etc/systemd/system/openvpn-server@server.service.d
printf '%s\n' "[Service]" "LimitNPROC=infinity" \
    > /etc/systemd/system/openvpn-server@server.service.d/override.conf

# ---- forwarding + NAT ----
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-aaa-ovpn.conf
sysctl --system >/dev/null 2>&1 || sysctl -w net.ipv4.ip_forward=1 >/dev/null
iptables -t nat -C POSTROUTING -s $OVPN_NET/24 ! -o tun+ -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s $OVPN_NET/24 ! -o tun+ -j MASQUERADE
iptables -C FORWARD -s $OVPN_NET/24 -j ACCEPT 2>/dev/null || iptables -A FORWARD -s $OVPN_NET/24 -j ACCEPT
iptables -C FORWARD -d $OVPN_NET/24 -j ACCEPT 2>/dev/null || iptables -A FORWARD -d $OVPN_NET/24 -j ACCEPT
netfilter-persistent save >/dev/null 2>&1 || true

# ---- client profile (same layout as the app's bundled ovpn_cert.ovpn) ----
# The app rewrites "remote <host> <port>" and replaces EVERY occurrence of that
# port number in the whole profile, so pick a placeholder port that does not
# appear anywhere else in it (the CA body is base64 and can contain digits).
REST=$(printf '%s\n' \
    "persist-remote-ip" \
    "resolv-retry infinite" \
    "connect-retry 0 1" \
    "remote-cert-tls server" \
    "nobind" \
    "reneg-sec 0" \
    "rcvbuf 0" \
    "sndbuf 0" \
    "verb 2" \
    "cipher $CIPHER" \
    "auth $AUTH" \
    "auth-nocache" \
    "setenv CLIENT_CERT 0" \
    "auth-user-pass" \
    "<ca>" \
    "$(cat "$PKI/ca.crt")" \
    "</ca>")
PH=$OVPN_PORT
while printf '%s' "$REST" | grep -q "$PH"; do PH=$((PH+1)); done
{
    echo "client"
    echo "dev tun"
    echo "persist-tun"
    echo "proto tcp"
    echo "remote 0.0.0.0 $PH"
    printf '%s\n' "$REST"
} > /etc/openvpn/client-tcp.ovpn
mkdir -p /home/vps/public_html
cp /etc/openvpn/client-tcp.ovpn /home/vps/public_html/client-tcp.ovpn 2>/dev/null || true

# ---- start ----
systemctl daemon-reload
systemctl enable openvpn-server@server >/dev/null 2>&1 || true
systemctl restart openvpn-server@server
sleep 2
if systemctl is-active --quiet openvpn-server@server && ss -tln | grep -q "127.0.0.1:$OVPN_PORT"; then
    echo -e "${green}[+] OpenVPN is running on 127.0.0.1:$OVPN_PORT${NC}"
else
    echo -e "${red}[-] OpenVPN failed to start - check: journalctl -u openvpn-server@server -e  /  /var/log/openvpn-aaa.log${NC}"
    exit 1
fi

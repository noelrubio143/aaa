#!/bin/bash
# AMBER VPN - self-signed certificate on the VPS IP (command: m-ssl)
#
# One certificate for everything:
#   /etc/xray/xray.crt + /etc/xray/xray.key   (same paths as before, so nothing else changes)
# gomux (ports 80/443) hot-reloads these files (re-checks every ~30s, no restart).
#
# Walang domain. Ang IP ng VPS ang gamit (auto-detect).
# Hindi trusted ang cert: sa client i-on ang allowInsecure / skip-cert-verify
# o i-pin ang SHA256 fingerprint na ipi-print sa dulo.
#
# Usage:  m-ssl [ip]        (kung walang ibinigay, ang public IP ng VPS)

RED='\e[1;31m'; GRN='\e[1;32m'; YEL='\e[1;33m'; BLU='\e[1;34m'; NC='\e[0m'

[ "$(id -u)" = 0 ] || { echo -e "${RED}Run as root.${NC}"; exit 1; }

CRT=/etc/xray/xray.crt
KEY=/etc/xray/xray.key

is_ip() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
die() { echo -e "${RED} $*${NC}"; exit 1; }

# ---- 1. IP
ip="$(printf %s "$1" | tr -d '[:space:]')"
[ -n "$ip" ] || ip="$(curl -s4 --max-time 10 ifconfig.me 2>/dev/null | tr -d '[:space:]')"
[ -n "$ip" ] || ip="$(wget -qO- --timeout=10 ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]')"
is_ip "$ip" || die "Hindi makuha ang IP ng VPS. Gamitin: m-ssl <ip>"

# ---- 2. self-signed cert (IP bilang SAN, 11 taon)
command -v openssl >/dev/null 2>&1 || { command -v apt-get >/dev/null 2>&1 && apt-get install -y openssl >/dev/null 2>&1; }
command -v openssl >/dev/null 2>&1 || die "Walang openssl."

echo -e " ${BLU}Gumagawa ng self-signed certificate para sa IP $ip ...${NC}"
mkdir -p /etc/xray /etc/v2ray /var/lib
cnf="$(mktemp)"
cat > "$cnf" <<EOC
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=$ip
[v3]
subjectAltName=IP:$ip
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
EOC
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -sha256 -days 4015 \
    -keyout "$KEY" -out "$CRT" -config "$cnf" 2>/dev/null
rc=$?
rm -f "$cnf"
{ [ $rc -eq 0 ] && [ -s "$CRT" ] && [ -s "$KEY" ]; } || die "Hindi nagawa ang self-signed certificate."
chmod 644 "$CRT"; chmod 600 "$KEY"

# ---- 3. the other scripts read the IP from these files
echo "$ip" > /etc/xray/domain
echo "$ip" > /etc/v2ray/domain
echo "$ip" > /root/domain
echo "IP=$ip" > /var/lib/ipvps.conf

fp="$(openssl x509 -in "$CRT" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)"
echo
echo -e " ${GRN}Tapos na. Self-signed certificate para sa IP $ip (11 taon).${NC}"
echo " Cert    : $CRT (isa lang para sa lahat)"
echo " SHA256  : $fp"
echo -e " ${YEL}Paalala: hindi ito trusted. Sa client, i-on ang allowInsecure / skip-cert-verify${NC}"
echo -e " ${YEL}         o i-pin ang SHA256 fingerprint sa itaas.${NC}"
systemctl is-active --quiet gomux 2>/dev/null && echo " Gagamitin ng gomux ang bagong cert sa loob ng ~30 segundo."
exit 0

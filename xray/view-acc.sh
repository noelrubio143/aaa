#!/bin/bash
###############################################################################
# View an existing account again (VLESS / VMess / Trojan -- WS and XHTTP)
#
#   usage: view-acc vless|vmess|trojan
#
# Accounts are read straight from /etc/xray/config.json (the "#& user exp",
# "### user exp" and "#! user exp" marker lines + the client line under them),
# and the links are rebuilt the same way the add-* scripts build them.
###############################################################################

proto="$1"
case "$proto" in
    vless)  back=m-vless  ;;
    vmess)  back=m-vmess  ;;
    trojan) back=m-trojan ;;
    *) echo "usage: view-acc vless|vmess|trojan"; exit 1 ;;
esac

CONFIG="${CONFIG:-/etc/xray/config.json}"
DOMAIN_FILE="${DOMAIN_FILE:-/etc/xray/domain}"
IPVPS_FILE="${IPVPS_FILE:-/var/lib/ipvps.conf}"

[ -f "$IPVPS_FILE" ] && source "$IPVPS_FILE"
if [[ -z "$IP" ]]; then
    domain=$(cat "$DOMAIN_FILE")
else
    domain=$IP
fi
tls=443
none=80
L="\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"

# --- read the accounts of this protocol: "<ws|xhttp> <user> <expired> <id>" --
data=$(awk -v proto="$proto" '
BEGIN {
    mp["#vless"]="vless";        mk["#vless"]="ws"
    mp["#vlessxhttp"]="vless";   mk["#vlessxhttp"]="xhttp"
    mp["#vmess"]="vmess";        mk["#vmess"]="ws"
    mp["#vmessxhttp"]="vmess";   mk["#vmessxhttp"]="xhttp"
    mp["#trojanws"]="trojan";    mk["#trojanws"]="ws"
    mp["#trojanxhttp"]="trojan"; mk["#trojanxhttp"]="xhttp"
    pre["vless"]="#& "; pre["vmess"]="### "; pre["trojan"]="#! "
    p = pre[proto]; plen = length(p)
}
{
    # previous line was an account line: this line holds its id/password
    if (pending) {
        pending = 0
        if (match($0, /"(id|password)":[ \t]*"[^"]+"/)) {
            s = substr($0, RSTART, RLENGTH)
            sub(/^"(id|password)":[ \t]*"/, "", s)
            sub(/"$/, "", s)
            print kind "\t" user "\t" expd "\t" s
        }
    }
    t = $0
    gsub(/^[ \t]+|[ \t]+$/, "", t)
    if (t in mp) { cur = mp[t]; ck = mk[t]; next }   # new inbound section
    if (cur == proto && substr($0, 1, plen) == p) {
        n = split(substr($0, plen + 1), f, " ")
        if (n >= 2) { user = f[1]; expd = f[2]; kind = ck; pending = 1 }
    }
}
' "$CONFIG")

title=$(echo "$proto" | sed 's/./\U&/')

clear
echo -e "$L"
echo -e "\E[44;1;39m      View AMBERVPN $title Account      \E[0m"
echo -e "$L"

if [[ -z "$data" ]]; then
    echo ""
    echo "No $title account found."
    echo ""
    read -n 1 -s -r -p "Press any key to back on menu"
    $back
    exit 0
fi

mapfile -t rows <<< "$data"
echo ""
printf " %-4s %-7s %-16s %s\n" "No" "Type" "User" "Expired"
echo -e "$L"
n=1
for r in "${rows[@]}"; do
    IFS=$'\t' read -r t u e id <<< "$r"
    printf " %-4s %-7s %-16s %s\n" "$n" "${t^^}" "$u" "$e"
    n=$((n + 1))
done
echo -e "$L"
echo ""
read -rp "Select number (0 = back): " pick

if ! [[ "$pick" =~ ^[0-9]+$ ]] || (( pick < 1 || pick > ${#rows[@]} )); then
    $back
    exit 0
fi

IFS=$'\t' read -r type user exp uuid <<< "${rows[$((pick - 1))]}"

# --- rebuild the links exactly like the add-* scripts ------------------------
vmess_link() {   # $1=port $2=net $3=path $4=type $5=tls
    local ins=""
    [ "$5" = "tls" ] && ins=", \"allowInsecure\": \"1\""   # self-signed cert on the VPS IP
    local j="{ \"v\": \"2\", \"ps\": \"${user}\", \"add\": \"${domain}\", \"port\": \"$1\", \"id\": \"${uuid}\", \"aid\": \"0\", \"net\": \"$2\", \"path\": \"$3\", \"type\": \"$4\", \"host\": \"\", \"tls\": \"$5\"${ins} }"
    echo "vmess://$(echo "$j" | base64 -w 0)"
}

case "$proto:$type" in
vless:ws)
    net="ws"; path="/vless"
    link1="vless://${uuid}@${domain}:$tls?path=/vless&security=tls&allowInsecure=1&encryption=none&type=ws#${user}"
    link2="vless://${uuid}@${domain}:$none?path=/vless&encryption=none&type=ws#${user}"
    head="AMBERVPN Vless Account" ;;
vless:xhttp)
    net="xhttp (mode packet-up)"; path="/xhttp-vless"
    link1="vless://${uuid}@${domain}:$tls?path=%2Fxhttp-vless&security=tls&allowInsecure=1&encryption=none&type=xhttp&mode=packet-up#${user}"
    link2="vless://${uuid}@${domain}:$none?path=%2Fxhttp-vless&security=none&encryption=none&type=xhttp&mode=packet-up#${user}"
    head="AMBERVPN Vless XHTTP Account" ;;
vmess:ws)
    net="ws"; path="/vmess"
    link1=$(vmess_link 443 ws /vmess none tls)
    link2=$(vmess_link 80 ws /vmess none none)
    head="AMBERVPN Vmess Account" ;;
vmess:xhttp)
    net="xhttp (mode packet-up)"; path="/xhttp-vmess"
    link1=$(vmess_link 443 xhttp /xhttp-vmess packet-up tls)
    link2=$(vmess_link 80 xhttp /xhttp-vmess packet-up none)
    head="AMBERVPN Vmess XHTTP Account" ;;
trojan:ws)
    net="ws"; path="/trojan-ws"
    link1="trojan://${uuid}@${domain}:${tls}?path=%2Ftrojan-ws&security=tls&allowInsecure=1&host=${domain}&type=ws#${user}"
    link2="trojan://${uuid}@${domain}:${none}?path=%2Ftrojan-ws&security=none&host=${domain}&type=ws#${user}"
    head="AMBERVPN Trojan Account" ;;
trojan:xhttp)
    net="xhttp (mode packet-up)"; path="/xhttp-trojan"
    link1="trojan://${uuid}@${domain}:${tls}?path=%2Fxhttp-trojan&security=tls&allowInsecure=1&host=${domain}&type=xhttp&mode=packet-up#${user}"
    link2="trojan://${uuid}@${domain}:${none}?path=%2Fxhttp-trojan&security=none&host=${domain}&type=xhttp&mode=packet-up#${user}"
    head="AMBERVPN Trojan XHTTP Account" ;;
esac

# --- show it -----------------------------------------------------------------
clear
echo -e "$L"
echo -e "\E[44;1;39m       ${head}        \E[0m"
echo -e "$L"
echo -e "Remarks        : ${user}"
echo -e "Domain         : ${domain}"
echo -e "Wildcard       : (bug.com).${domain}"
echo -e "Port TLS       : $tls"
echo -e "Port none TLS  : $none"
case "$proto" in
vless)
    echo -e "id             : ${uuid}"
    echo -e "Encryption     : none" ;;
vmess)
    echo -e "id             : ${uuid}"
    echo -e "alterId        : 0"
    echo -e "Security       : auto" ;;
trojan)
    echo -e "Key            : ${uuid}" ;;
esac
echo -e "Network        : ${net}"
echo -e "Path           : ${path}"
echo -e "$L"
echo -e "Link TLS       : ${link1}"
echo -e "$L"
echo -e "Link none TLS  : ${link2}"
echo -e "$L"
echo -e "Expired On     : $exp"
echo -e "$L"

# Slipstream Xray (DNS tunnel): vless/tcp link, only for vless ws accounts that
# are also registered on the #slipvless inbound
SLIP_XRAY_CONF="/etc/slipstream-rust/slipstream-rust-xray.conf"
SLIP_LINK_PORT=53   # port shown in the slipstream vless/tcp link (change if your client app needs another)
if [[ "$proto:$type" == "vless:ws" && -f "$SLIP_XRAY_CONF" ]] && \
   awk -v u="$user" '/^#slipvless$/ {on=1; next} on && /^#& / {if ($2==u) f=1; next} on && !/^ *}/ && !/^#& / && !/"id"/ && !/"email"/ {on=0} END {exit !f}' "$CONFIG"; then
    slipdom=$(grep '^DOMAIN=' "$SLIP_XRAY_CONF" | cut -d'"' -f2)
    echo -e "\E[44;1;39m     CONFIG SLIPSTREAM XRAY (DNS)     \E[0m"
    echo -e "$L"
    echo -e "NS Domain   : ${slipdom}"
    echo -e "id          : ${uuid}"
    echo -e "Protocol    : vless (tcp, security none)"
    echo -e "Link TCP    : vless://${uuid}@${slipdom}:${SLIP_LINK_PORT}?type=tcp&security=none&encryption=none#${user}-slip"
    echo -e "Note        : pick Slipstream (DNS Tunnel) in the client app and"
    echo -e "              use this domain as the Nameserver/Domain."
    echo -e "$L"
fi
echo ""
read -n 1 -s -r -p "Press any key to back on menu"

$back

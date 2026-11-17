#!/bin/bash

# dnstt Server Setup Script
# Three independent instances share one binary, same as vaydns/slipstream:
#   ssh   -> dnstt-ssh   (UDP 5320) -> local SSH port
#   xray  -> dnstt-xray  (UDP 5321) -> Xray vless/tcp inbound 127.0.0.1:14020
#   ovpn  -> dnstt-ovpn  (UDP 5322) -> OpenVPN (tcp) 127.0.0.1:1194
#   all   -> dnstt-all   (UDP 5323) -> gomux edge 127.0.0.1:80 (SSH + OpenVPN + Xray ws paths, one domain)
# Public UDP/53 is split between ALL the DNS tunnels (slipstream, vaydns,
# dnstt) by the domain inside the query, so each instance needs its own domain.

trap 'echo ""; read -rp "Pindutin ang Enter para bumalik sa menu... " _' EXIT

if [[ $EUID -ne 0 ]]; then
    echo -e "\033[0;31m[ERROR]\033[0m This script must be run as root"
    exit 1
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/dnstt"
BUILD_DIR="/opt/dnstt"
SYSTEMD_DIR="/etc/systemd/system"
DNSTT_USER="dnstt"
BIN="${INSTALL_DIR}/dnstt-server"
PRIV_KEY="${CONFIG_DIR}/server.key"
PUB_KEY="${CONFIG_DIR}/server.pub"
NAT_APPLY_SCRIPT="/usr/local/bin/dnstt-nat-apply"
NAT_SERVICE="dnstt-nat"
XRAY_JSON="/etc/xray/config.json"
GO_VER="1.27.2"
ASSET_BASE="https://github.com/noelrubio143/aaa/releases/download/assets"
DNSTT_ZIP="dnstt-20260501.zip"
REPO_MAIN="https://www.bamsoftware.com/git/dnstt.git"
REPO_MIRROR="https://github.com/gharib-uk/dnstt"

ALL_COMPS=(ssh xray ovpn all)
SSH_PORT_DNSTT="5320"
XRAY_PORT_DNSTT="5321"
OVPN_PORT_DNSTT="5322"
ALL_PORT_DNSTT="5323"
ALL_TARGET_PORT="80"
XRAY_TARGET_PORT="14020"
OVPN_TARGET_PORT="1194"

print_status()   { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning()  { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()    { echo -e "${RED}[ERROR]${NC} $1"; }
print_question() { echo -ne "${BLUE}[QUESTION]${NC} $1"; }

comp_service() { echo "dnstt-$1"; }
comp_conf()    { echo "${CONFIG_DIR}/dnstt-$1.conf"; }
comp_port()    { case "$1" in xray) echo "$XRAY_PORT_DNSTT" ;; ovpn) echo "$OVPN_PORT_DNSTT" ;; all) echo "$ALL_PORT_DNSTT" ;; *) echo "$SSH_PORT_DNSTT" ;; esac; }
comp_label()   { case "$1" in xray) echo "Xray vless" ;; ovpn) echo "OpenVPN" ;; all) echo "ALL-in-one (gomux)" ;; *) echo "SSH" ;; esac; }
comp_domain()  { local f; f=$(comp_conf "$1"); if [ -f "$f" ]; then grep '^DOMAIN=' "$f" | cut -d'"' -f2; fi; return 0; }
is_installed() { [ -f "$(comp_conf "$1")" ]; }

detect_ssh_port() {
    local p
    p=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | awk -F: '{print $NF}' | head -1)
    echo "${p:-22}"
}

comp_target() {
    case "$1" in
        xray) echo "$XRAY_TARGET_PORT" ;;
        ovpn) echo "$OVPN_TARGET_PORT" ;;
        all)  echo "$ALL_TARGET_PORT" ;;
        *)    detect_ssh_port ;;
    esac
}

# ---------------------------------------------------------------- build
install_deps() {
    print_status "Installing dependencies (git, curl, iptables)..."
    export DEBIAN_FRONTEND=noninteractive
    if command -v apt-get &>/dev/null; then
        apt-get update -y &>/dev/null || true
        apt-get install -y git curl iptables ca-certificates tar unzip &>/dev/null || true
    elif command -v dnf &>/dev/null; then
        dnf install -y git curl iptables ca-certificates tar unzip &>/dev/null || true
    elif command -v yum &>/dev/null; then
        yum install -y git curl iptables ca-certificates tar unzip &>/dev/null || true
    fi
}

go_ok() {
    command -v go &>/dev/null || return 1
    local v maj min
    v=$(go version | awk '{print $3}' | sed 's/^go//')
    maj=${v%%.*}; min=${v#*.}; min=${min%%.*}
    [ "$maj" -gt 1 ] 2>/dev/null || [ "$min" -ge 21 ] 2>/dev/null
}

ensure_go() {
    export PATH="/usr/local/go-dnstt/bin:$PATH"
    if go_ok; then return 0; fi
    print_status "Installing Go ${GO_VER} (for building dnstt)..."
    local arch
    case "$(uname -m)" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *) print_error "Unsupported CPU: $(uname -m)"; return 1 ;;
    esac
    local tgz="go${GO_VER}.linux-${arch}.tar.gz"
    if ! curl -fsSL "${ASSET_BASE}/${tgz}" -o /tmp/go-dnstt.tgz; then
        print_warning "Go not found in GitHub assets, trying go.dev..."
        if ! curl -fsSL "https://go.dev/dl/${tgz}" -o /tmp/go-dnstt.tgz; then
            print_error "Could not download Go. Check the VPS internet connection."
            return 1
        fi
    fi
    rm -rf /usr/local/go-dnstt && mkdir -p /usr/local/go-dnstt
    tar -C /usr/local/go-dnstt --strip-components=1 -xzf /tmp/go-dnstt.tgz
    rm -f /tmp/go-dnstt.tgz
    go_ok
}

build_dnstt() {
    if [ -x "$BIN" ]; then return 0; fi
    install_deps
    ensure_go || return 1
    print_status "Building dnstt-server from source..."
    mkdir -p "$BUILD_DIR"
    rm -rf "$BUILD_DIR/src"
    # 1) source zip from the GitHub assets release, 2) upstream git, 3) mirror
    local got=0
    if curl -fsSL "${ASSET_BASE}/${DNSTT_ZIP}" -o "$BUILD_DIR/dnstt.zip" \
        && unzip -q -o "$BUILD_DIR/dnstt.zip" -d "$BUILD_DIR/unz"; then
        local d
        d=$(find "$BUILD_DIR/unz" -maxdepth 2 -type d -name dnstt-server | head -1)
        if [ -n "$d" ]; then
            mv "$(dirname "$d")" "$BUILD_DIR/src"
            got=1
        fi
        rm -rf "$BUILD_DIR/unz" "$BUILD_DIR/dnstt.zip"
    fi
    if [ "$got" -eq 0 ]; then
        print_warning "Source zip unavailable, trying git..."
        git clone --depth 1 "$REPO_MAIN" "$BUILD_DIR/src" &>/dev/null \
            || git clone --depth 1 "$REPO_MIRROR" "$BUILD_DIR/src" &>/dev/null \
            || { print_error "Could not get dnstt source."; return 1; }
    fi
    if ! (cd "$BUILD_DIR/src/dnstt-server" && go build -o "$BIN" .); then
        print_error "dnstt-server build failed."
        return 1
    fi
    chmod +x "$BIN"
    print_status "dnstt-server built: $BIN"
}

ensure_user_and_keys() {
    id "$DNSTT_USER" &>/dev/null || useradd -r -s /usr/sbin/nologin -M "$DNSTT_USER"
    mkdir -p "$CONFIG_DIR"
    if [ ! -f "$PRIV_KEY" ] || [ ! -f "$PUB_KEY" ]; then
        print_status "Generating server keypair..."
        "$BIN" -gen-key -privkey-file "$PRIV_KEY" -pubkey-file "$PUB_KEY" &>/dev/null || {
            print_error "Key generation failed."; return 1; }
    fi
    chown "$DNSTT_USER":"$DNSTT_USER" "$PRIV_KEY" "$PUB_KEY"
    chmod 600 "$PRIV_KEY"; chmod 644 "$PUB_KEY"
}

# ---------------------------------------------------------------- xray inbound
ensure_xray_inbound() {
    if [ ! -f "$XRAY_JSON" ]; then
        print_error "Xray config not found at $XRAY_JSON. Install Xray first (setup1.sh)."
        return 1
    fi
    if grep -q '^#dnstt-inbound-begin$' "$XRAY_JSON"; then
        print_status "Xray dnstt inbound already present"
        return 0
    fi
    print_status "Adding Xray dnstt inbound (127.0.0.1:${XRAY_TARGET_PORT}, vless/tcp)..."
    local tmp seed uuid backup
    tmp=$(mktemp); seed=$(mktemp)
    uuid=$(cat /proc/sys/kernel/random/uuid)
    # copy existing plain-vless accounts so they also work over dnstt
    awk '/^#vless$/ {on=1; next} on && /^#& / {u=$2; e=$3; if ((getline nx) > 0) { print "#& " u " " e; print nx } next} {on=0}' "$XRAY_JSON" > "$seed"
    {
        echo '#dnstt-inbound-begin'
        cat << EOF
    {
      "listen": "127.0.0.1",
      "port": ${XRAY_TARGET_PORT},
      "protocol": "vless",
      "tag": "dnstt-vless",
      "settings": {
        "decryption": "none",
        "clients": [
          {
            "id": "${uuid}"
#dnsttvless
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
        echo '#dnstt-inbound-end'
    } > "$tmp"

    backup="${XRAY_JSON}.bak-dnstt"
    cp "$XRAY_JSON" "$backup"
    sed -i '/"inbounds": \[/r '"$tmp" "$XRAY_JSON"
    rm -f "$tmp" "$seed"

    if command -v xray &>/dev/null && xray run -test -config "$backup" &>/dev/null; then
        if ! xray run -test -config "$XRAY_JSON" &>/dev/null; then
            print_error "Xray rejected the new config; restoring the previous one."
            cp "$backup" "$XRAY_JSON"
            return 1
        fi
    fi
    systemctl restart xray 2>/dev/null || print_warning "Could not restart xray - restart it manually"
}

remove_xray_inbound() {
    [ -f "$XRAY_JSON" ] || return 0
    grep -q '^#dnstt-inbound-begin$' "$XRAY_JSON" || return 0
    sed -i '/^#dnstt-inbound-begin$/,/^#dnstt-inbound-end$/d' "$XRAY_JSON"
    systemctl restart xray 2>/dev/null || true
}

# ---------------------------------------------------------------- nat (UDP/53 split by domain)
write_nat_apply_script() {
    cat > "$NAT_APPLY_SCRIPT" << 'NAT_APPLY_EOF'
#!/bin/bash
# dnstt-nat-apply: (re)build the UDP/53 redirect rules for dnstt.
# Generated by dnstt-deploy - safe to run repeatedly. Own chains only, so it
# lives side by side with SLIPSTREAM_DNS and VAYDNS_DNS.

CONF_DIR="/etc/dnstt"
CHAIN="DNSTT_DNS"
RATE_CHAIN="DNSTT_DNS_RATE"
RATE_LIMIT_NAME="dnstt_dns_rl"
RATE_LIMIT_QPS="150"
RATE_LIMIT_BURST="300"
SSH_PORT=5320
XRAY_PORT=5321
OVPN_PORT=5322
ALL_PORT=5323

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

rules=(); ports=()
while read -r hex port; do
    [ -n "$hex" ] || continue
    rules+=("$hex $port"); ports+=("$port")
done < <(
    for pair in "ssh:$SSH_PORT" "xray:$XRAY_PORT" "ovpn:$OVPN_PORT" "all:$ALL_PORT"; do
        name="${pair%%:*}"; port="${pair##*:}"
        conf="$CONF_DIR/dnstt-${name}.conf"
        [ -f "$conf" ] || continue
        d=$(grep '^DOMAIN=' "$conf" | cut -d'"' -f2)
        [ -n "$d" ] || continue
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

    while $ipt -t nat -D PREROUTING -i "$IFACE" -p udp --dport 53 -j "$CHAIN" 2>/dev/null; do :; done
    $ipt -t nat -F "$CHAIN" 2>/dev/null; $ipt -t nat -X "$CHAIN" 2>/dev/null
    while $ipt -t raw -D PREROUTING -i "$IFACE" -p udp --dport 53 -j "$RATE_CHAIN" 2>/dev/null; do :; done
    $ipt -t raw -F "$RATE_CHAIN" 2>/dev/null; $ipt -t raw -X "$RATE_CHAIN" 2>/dev/null
    for p in "$SSH_PORT" "$XRAY_PORT" "$OVPN_PORT" "$ALL_PORT"; do
        while $ipt -D INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null; do :; done
    done

    [ "${#rules[@]}" -gt 0 ] || continue

    if $ipt -t raw -N "$RATE_CHAIN" 2>/dev/null; then
        if $ipt -t raw -A "$RATE_CHAIN" -p udp \
            -m hashlimit --hashlimit-above "${RATE_LIMIT_QPS}/sec" \
            --hashlimit-burst "$RATE_LIMIT_BURST" --hashlimit-mode srcip \
            --hashlimit-name "$RATE_LIMIT_NAME" --hashlimit-htable-expire 10000 \
            -j DROP 2>/dev/null; then
            $ipt -t raw -I PREROUTING -i "$IFACE" -p udp --dport 53 -j "$RATE_CHAIN" 2>/dev/null
        else
            $ipt -t raw -X "$RATE_CHAIN" 2>/dev/null
        fi
    fi

    if ! $ipt -t nat -N "$CHAIN" 2>/dev/null; then
        [ "$ipt" = "iptables" ] && { echo "cannot create nat chain $CHAIN" >&2; rc=1; }
        continue
    fi
    for r in "${rules[@]}"; do
        hex="${r% *}"; port="${r##* }"
        if ! $ipt -t nat -A "$CHAIN" -p udp -m string --algo bm $ICASE --hex-string "$hex" -j REDIRECT --to-ports "$port" 2>/dev/null; then
            [ "$ipt" = "iptables" ] && { echo "iptables string match not supported (xt_string)" >&2; rc=1; }
        fi
    done
    $ipt -t nat -I PREROUTING -i "$IFACE" -p udp --dport 53 -j "$CHAIN" 2>/dev/null || rc=1
    for p in "${ports[@]}"; do
        $ipt -I INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null
    done
done
exit $rc
NAT_APPLY_EOF
    chmod +x "$NAT_APPLY_SCRIPT"

    # re-apply the rules at every boot
    cat > "${SYSTEMD_DIR}/${NAT_SERVICE}.service" << EOF
[Unit]
Description=dnstt UDP/53 redirect rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${NAT_APPLY_SCRIPT}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$NAT_SERVICE" &>/dev/null
}

apply_nat() {
    [ -x "$NAT_APPLY_SCRIPT" ] || write_nat_apply_script
    "$NAT_APPLY_SCRIPT" || print_warning "Some NAT rules could not be applied (kernel xt_string/xt_hashlimit missing?)"
}

# Shared UDP/network tuning for all DNS tunnels (slipstream / vaydns / dnstt).
# Safe to run repeatedly: one file, rewritten each time.
apply_dns_tunnel_sysctl() {
    local f="/etc/sysctl.d/99-dns-tunnel.conf"
    {
        echo "# DNS tunnel tuning (slipstream / vaydns / dnstt)"
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

# ---------------------------------------------------------------- ipv6
# True when the VPS has a real (non-loopback, non-link-local) IPv6 address.
has_ipv6_addresses() {
    [ -f /proc/net/if_inet6 ] || return 1
    local a
    if command -v timeout &>/dev/null; then
        a=$(timeout 2 ip -6 addr show scope global 2>/dev/null | grep -E "inet6 [0-9a-fA-F:]+" || true)
    else
        a=$(ip -6 addr show scope global 2>/dev/null | grep -E "inet6 [0-9a-fA-F:]+" || true)
    fi
    [ -n "$a" ]
}

# Listen address for dnstt-server's -udp flag: dual-stack [::] when IPv6 exists,
# plain 0.0.0.0 otherwise (same logic as slipstream / vaydns deploy scripts).
dns_listen_addr() {
    local port="$1"
    if command -v ip6tables &>/dev/null && has_ipv6_addresses; then
        echo "[::]:${port}"
    else
        echo "0.0.0.0:${port}"
    fi
}

# ---------------------------------------------------------------- instances
create_service() {
    local comp="$1" domain="$2" port target svc
    port=$(comp_port "$comp"); target=$(comp_target "$comp"); svc=$(comp_service "$comp")

    cat > "$(comp_conf "$comp")" << EOF
DOMAIN="${domain}"
PORT="${port}"
TARGET="127.0.0.1:${target}"
EOF

    local listen_addr
    listen_addr=$(dns_listen_addr "$port")
    if [[ "$listen_addr" == "[::]"* ]]; then
        print_status "IPv6 detected: dnstt (${comp}) listening dual-stack on ${listen_addr}"
    else
        print_status "No IPv6 address on this VPS: dnstt (${comp}) listening IPv4 only on ${listen_addr}"
    fi

    local after="network.target"
    [ "$comp" = "xray" ] && after="network.target xray.service"
    [ "$comp" = "ovpn" ] && after="network.target openvpn-server@server.service"
    [ "$comp" = "all" ] && after="network.target gomux.service"

    cat > "${SYSTEMD_DIR}/${svc}.service" << EOF
[Unit]
Description=dnstt DNS Tunnel Server ($(comp_label "$comp"))
After=${after}
Wants=network.target

[Service]
Type=simple
User=${DNSTT_USER}
ExecStart=${BIN} -udp ${listen_addr} -privkey-file ${PRIV_KEY} ${domain} 127.0.0.1:${target}
Restart=always
RestartSec=3
LimitNOFILE=65535
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$svc" &>/dev/null
    systemctl restart "$svc"
}

ask_domain() {
    local comp="$1" d cur
    cur=$(comp_domain "$comp")
    while true; do
        print_question "Tunnel domain for $(comp_label "$comp") (NS subdomain, e.g. t.example.com)${cur:+ [$cur]}: "
        read -r d
        d="${d:-$cur}"
        d="${d,,}"
        if [[ "$d" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
            # each tunnel instance (and each of slipstream/vaydns) needs its own domain
            for c in "${ALL_COMPS[@]}"; do
                [ "$c" = "$comp" ] && continue
                if [ "$(comp_domain "$c")" = "$d" ]; then
                    print_error "Domain already used by dnstt $(comp_label "$c"). Use a different one."
                    continue 2
                fi
            done
            for f in /etc/vaydns/vaydns-*.conf /etc/slipstream-rust/*.conf; do
                [ -f "$f" ] || continue
                if grep -q "^DOMAIN=\"${d}\"" "$f" 2>/dev/null; then
                    print_error "Domain already used by $f. Use a different one."
                    continue 2
                fi
            done
            DOMAIN_ANSWER="$d"; return 0
        fi
        print_error "Invalid domain."
    done
}

show_info() {
    local any=0 c
    for c in "${ALL_COMPS[@]}"; do
        is_installed "$c" || continue
        any=1
        echo ""
        echo -e "${GREEN}== dnstt $(comp_label "$c") ==${NC}"
        echo "  Domain  : $(comp_domain "$c")"
        echo "  Service : $(comp_service "$c")  [$(systemctl is-active "$(comp_service "$c")" 2>/dev/null)]"
        echo "  Listen  : UDP $(comp_port "$c") (public UDP/53 redirected by domain)"
        echo "  Target  : $(grep '^TARGET=' "$(comp_conf "$c")" | cut -d'"' -f2)"
        if [ "$c" = "all" ]; then
            echo "  Inside  : raw SSH, raw OpenVPN (tcp), or Xray over HTTP ws paths (/vless /vmess /trojan-ws /xhttp-*)."
            echo "            Raw vless/tcp is NOT available in this mode."
        fi
    done
    if [ "$any" -eq 0 ]; then
        print_warning "No dnstt instance installed yet."
        return
    fi
    echo ""
    echo -e "${YELLOW}Public key (for the client, -pubkey):${NC}"
    cat "$PUB_KEY" 2>/dev/null
    echo ""
    echo "DNS records needed for each domain (example for t.example.com):"
    echo "  ns.example.com   A    <IP ng VPS>"
    echo "  t.example.com    NS   ns.example.com"
    echo ""
    echo "Client example (DoH):"
    echo "  dnstt-client -doh https://1.1.1.1/dns-query -pubkey-file server.pub <domain> 127.0.0.1:7000"
    echo "Client example (UDP, mas mabilis kung pwede):"
    echo "  dnstt-client -udp 8.8.8.8:53 -pubkey-file server.pub <domain> 127.0.0.1:7000"
    echo "Client example (UDP, IPv6 resolver - kailangan ng [ ] at port):"
    echo "  dnstt-client -udp [2001:4860:4860::8888]:53 -pubkey-file server.pub <domain> 127.0.0.1:7000"
    if has_ipv6_addresses; then
        echo ""
        echo "AAAA record for IPv6 (optional, para sa IPv6-only na clients):"
        echo "  ns.example.com   AAAA <IPv6 ng VPS>"
    fi
}

install_instance() {
    local comp="$1"
    build_dnstt || return 1
    ensure_user_and_keys || return 1
    ask_domain "$comp"
    if [ "$comp" = "xray" ]; then ensure_xray_inbound || return 1; fi
    if [ "$comp" = "ovpn" ] && ! ss -tln 2>/dev/null | grep -q ":${OVPN_TARGET_PORT} "; then
        print_warning "OpenVPN (tcp) is not listening on ${OVPN_TARGET_PORT} yet. Install it first (setup1.sh / ovpn)."
    fi
    if [ "$comp" = "all" ] && ! ss -tln 2>/dev/null | grep -q ":${ALL_TARGET_PORT} "; then
        print_warning "Nothing is listening on port ${ALL_TARGET_PORT} yet. Install gomux first (setup1.sh / xray/ins-gomux.sh)."
    fi
    create_service "$comp" "$DOMAIN_ANSWER"
    apply_dns_tunnel_sysctl
    write_nat_apply_script
    apply_nat
    sleep 1
    if systemctl is-active --quiet "$(comp_service "$comp")"; then
        print_status "dnstt $(comp_label "$comp") is running."
    else
        print_error "Service failed to start. Check: journalctl -u $(comp_service "$comp") -n 30"
    fi
    show_info
}

uninstall_instance() {
    local comp="$1" svc
    is_installed "$comp" || { print_warning "dnstt $(comp_label "$comp") is not installed."; return; }
    svc=$(comp_service "$comp")
    systemctl disable --now "$svc" &>/dev/null
    rm -f "${SYSTEMD_DIR}/${svc}.service" "$(comp_conf "$comp")"
    [ "$comp" = "xray" ] && remove_xray_inbound
    systemctl daemon-reload
    apply_nat
    print_status "dnstt $(comp_label "$comp") removed."

    local left=0 c
    for c in "${ALL_COMPS[@]}"; do is_installed "$c" && left=1; done
    if [ "$left" -eq 0 ]; then
        systemctl disable --now "$NAT_SERVICE" &>/dev/null
        rm -f "${SYSTEMD_DIR}/${NAT_SERVICE}.service" "$NAT_APPLY_SCRIPT"
        systemctl daemon-reload
        print_status "Last instance removed (binary and keys kept in $BIN / $CONFIG_DIR)."
    fi
}

status_all() {
    local c any=0
    for c in "${ALL_COMPS[@]}"; do
        is_installed "$c" || continue
        any=1
        printf "  %-12s %-22s %s\n" "$(comp_label "$c")" "$(comp_domain "$c")" "$(systemctl is-active "$(comp_service "$c")" 2>/dev/null)"
    done
    [ "$any" -eq 1 ] || echo "  (wala pang naka-install)"
}

# ---------------------------------------------------------------- menu
while true; do
    clear
    echo -e "${BLUE}============================================${NC}"
    echo -e "${GREEN}            dnstt DNS Tunnel Manager${NC}"
    echo -e "${BLUE}============================================${NC}"
    status_all
    echo ""
    echo "1) Install/Reconfigure dnstt - SSH (UDP ${SSH_PORT_DNSTT})"
    echo "2) Install/Reconfigure dnstt - Xray vless/tcp (UDP ${XRAY_PORT_DNSTT})"
    echo "3) Install/Reconfigure dnstt - OpenVPN tcp (UDP ${OVPN_PORT_DNSTT})"
    echo "4) Install/Reconfigure dnstt - ALL-in-one: SSH + OpenVPN + Xray ws (UDP ${ALL_PORT_DNSTT})"
    echo "5) Show info / public key"
    echo "6) Restart all dnstt services"
    echo "7) Uninstall dnstt"
    echo "0) Exit"
    echo ""
    print_question "Choose: "
    read -r choice
    case "$choice" in
        1) install_instance ssh ;;
        2) install_instance xray ;;
        3) install_instance ovpn ;;
        4) install_instance all ;;
        5) show_info ;;
        6) for c in "${ALL_COMPS[@]}"; do is_installed "$c" && systemctl restart "$(comp_service "$c")"; done; apply_nat; print_status "Restarted." ;;
        7) for c in "${ALL_COMPS[@]}"; do is_installed "$c" && uninstall_instance "$c"; done ;;
        0) exit 0 ;;
        *) print_error "Invalid option" ;;
    esac
    echo ""
    read -rp "Pindutin ang Enter para magpatuloy... " _
done

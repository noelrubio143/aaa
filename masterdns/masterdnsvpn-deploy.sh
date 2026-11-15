#!/bin/bash
# MasterDnsVPN server - install / manage menu (DNS Tunnel)
# Upstream: https://github.com/masterking32/MasterDnsVPN
#
# Installs to /usr/local/bin/masterdnsvpn-deploy (via ssh-vpn.sh) and is run
# from the main menu. Works alongside slipstream: slipstream grabs its own
# domain with an iptables QNAME match on UDP 53, everything else reaches this
# server on UDP 53 -- so USE A DIFFERENT DOMAIN than slipstream's.
#
# NOTE: do NOT run the upstream server_linux_install.sh on this VPS -- it deletes
# every NAT REDIRECT rule on port 53, which breaks slipstream's redirect.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

INSTALL_DIR="/opt/masterdnsvpn"
BIN="${INSTALL_DIR}/masterdnsvpn-server"
CONF="${INSTALL_DIR}/server_config.toml"
KEYFILE="${INSTALL_DIR}/encrypt_key.txt"
SERVICE="masterdnsvpn"
UNIT="/etc/systemd/system/${SERVICE}.service"
REL_BASE="https://github.com/masterking32/MasterDnsVPN/releases/latest/download"
RAW_BASE="https://raw.githubusercontent.com/masterking32/MasterDnsVPN/main"

ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
info() { echo -e "${BLUE}[..]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[X]${NC} $*"; }
pause() { echo ""; read -rp "Pindutin ang Enter para bumalik sa menu... " _; }

if [[ $EUID -ne 0 ]]; then
    err "Kailangan i-run bilang root."
    exit 1
fi

# ---------------------------------------------------------------- helpers

ensure_tools() {
    local need=()
    for t in curl unzip; do command -v "$t" >/dev/null 2>&1 || need+=("$t"); done
    [[ ${#need[@]} -eq 0 ]] && return 0
    info "Nag-i-install ng: ${need[*]}"
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}" ca-certificates
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "${need[@]}" ca-certificates
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "${need[@]}" ca-certificates
    else
        err "Walang apt/dnf/yum. I-install mo manually: ${need[*]}"
        return 1
    fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   ARCH="AMD64" ;;
        aarch64|arm64)  ARCH="ARM64" ;;
        armv7l|armv7)   ARCH="ARMV7" ;;
        armv6l)         ARCH="ARMV6" ;;
        i386|i686)      ARCH="X86" ;;
        *) err "Hindi supported ang arch: $(uname -m)"; return 1 ;;
    esac
}

# set_toml KEY 'RAW_VALUE'  -> replaces the line if present, else appends
set_toml() {
    local key="$1" val="$2"
    if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$CONF"; then
        sed -i -E "s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = ${val}|" "$CONF"
    else
        echo "${key} = ${val}" >> "$CONF"
    fi
}

get_toml() {
    grep -E "^[[:space:]]*$1[[:space:]]*=" "$CONF" 2>/dev/null | head -1 \
        | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*#.*$//'
}

is_installed() { [[ -x "$BIN" && -f "$CONF" ]]; }

svc_state() {
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        echo -e "${GREEN}Running${NC}"
    elif [[ -f "$UNIT" ]]; then
        echo -e "${RED}Stopped${NC}"
    else
        echo -e "${YELLOW}Not installed${NC}"
    fi
}

toml_ver() { grep -E '^[[:space:]]*CONFIG_VERSION[[:space:]]*=' "$1" 2>/dev/null | head -1 | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]"]//g'; }

# SSH port the server's sshd really listens on (fallback 22)
detect_ssh_port() {
    local p
    p=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
    [[ "$p" =~ ^[0-9]+$ ]] || p=$(ss -H -ltnp 2>/dev/null | awk '/"sshd"/{n=split($4,a,":"); print a[n]; exit}')
    [[ "$p" =~ ^[0-9]+$ ]] || p=22
    echo "$p"
}

# the server only accepts a key whose length matches the method, otherwise it
# silently regenerates and overwrites the key file: 3=16, 4=24, everything else=32
key_len_for() {
    case "$1" in
        3) echo 16 ;;
        4) echo 24 ;;
        *) echo 32 ;;
    esac
}

method_name() {
    case "$1" in
        0) echo "None" ;; 1) echo "XOR" ;; 2) echo "ChaCha20 (walang authentication)" ;;
        3) echo "AES-128-GCM" ;; 4) echo "AES-192-GCM" ;; 5) echo "AES-256-GCM" ;;
        *) echo "?" ;;
    esac
}

# ---------------------------------------------------------------- kernel tuning
# The server asks for 8 MB UDP buffers (SOCKET_BUFFER_SIZE). If net.core.rmem_max
# is the stock ~200 KB the kernel silently caps it and UDP packets get dropped
# under load -> slow tunnel. Same values as upstream's own installer.

tune_kernel() {
    cat > /etc/sysctl.d/99-masterdnsvpn.conf <<'EOF'
# MasterDnsVPN high-load tuning
fs.file-max = 2097152
fs.nr_open = 2097152
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 16384
net.core.optmem_max = 25165824
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.udp_mem = 65536 131072 262144
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_udp_timeout = 15
net.netfilter.nf_conntrack_udp_timeout_stream = 60
net.ipv4.ip_local_port_range = 10240 65535
EOF
    # conntrack keys may not exist yet; that must not stop the other keys
    sysctl -q -p /etc/sysctl.d/99-masterdnsvpn.conf >/dev/null 2>&1

    cat > /etc/security/limits.d/99-masterdnsvpn.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

    local rmax
    rmax=$(sysctl -n net.core.rmem_max 2>/dev/null)
    if [[ "${rmax:-0}" -ge 8388608 ]]; then
        ok "UDP buffer limit (rmem_max): ${rmax}"
    else
        warn "rmem_max = ${rmax:-?} pa rin (maliit). Baka hindi pinapayagan ng VPS mo (OpenVZ/LXC) na baguhin ang kernel settings."
    fi
}

remove_tuning() {
    local changed=0
    [[ -f /etc/sysctl.d/99-masterdnsvpn.conf ]] && { rm -f /etc/sysctl.d/99-masterdnsvpn.conf; changed=1; }
    [[ -f /etc/security/limits.d/99-masterdnsvpn.conf ]] && rm -f /etc/security/limits.d/99-masterdnsvpn.conf
    [[ $changed -eq 1 ]] && sysctl --system >/dev/null 2>&1
    return 0
}

do_tune() {
    tune_kernel
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        systemctl restart "$SERVICE" && ok "Na-restart ang server para magamit ang bagong buffer."
    fi
}

# new release with a newer CONFIG_VERSION -> start from the new template, but keep
# our own settings; the old file is saved next to it
migrate_config() {
    local sample="${INSTALL_DIR}/server_config.toml.sample"
    [[ -f "$CONF" && -f "$sample" ]] || return 0
    local old_v new_v
    old_v=$(toml_ver "$CONF"); new_v=$(toml_ver "$sample")
    [[ -z "$new_v" || "$old_v" == "$new_v" ]] && return 0

    warn "Bagong CONFIG_VERSION (${old_v:-wala} -> ${new_v}). Gagamit ng bagong template, ililipat ang settings mo."
    local k saved=()
    for k in DOMAIN DATA_ENCRYPTION_METHOD ENCRYPTION_KEY_FILE UDP_PORT PROTOCOL_TYPE FORWARD_IP FORWARD_PORT USE_EXTERNAL_SOCKS5; do
        saved+=("${k}=$(get_toml "$k")")
    done
    local bak="${CONF}.old-v${old_v:-x}-$(date +%Y%m%d%H%M%S)"
    cp -a "$CONF" "$bak"
    cp -f "$sample" "$CONF"
    local kv
    for kv in "${saved[@]}"; do
        [[ -n "${kv#*=}" ]] && set_toml "${kv%%=*}" "${kv#*=}"
    done
    ok "Na-migrate ang config. Lumang file: $bak (kung may custom tweaks ka, ilipat mo)."
}

# ---------------------------------------------------------------- port 53

free_port_53() {
    # What is bound to UDP 53 right now? (ignore our own service)
    local holders
    holders=$(ss -H -lunp 2>/dev/null | awk '$4 ~ /:53$/ {print $0}' | grep -v "masterdnsvpn" )
    [[ -z "$holders" ]] && return 0

    if echo "$holders" | grep -q "systemd-resolve"; then
        warn "Ginagamit ng systemd-resolved ang port 53. Pinapatay ang stub listener lang..."
        mkdir -p /etc/systemd/resolved.conf.d
        printf '[Resolve]\nDNSStubListener=no\n' > /etc/systemd/resolved.conf.d/masterdnsvpn.conf
        systemctl restart systemd-resolved 2>/dev/null
        # resolv.conf must not keep pointing at the (now dead) 127.0.0.53 stub
        if [[ -L /etc/resolv.conf ]] && readlink -f /etc/resolv.conf | grep -q "stub-resolv.conf"; then
            ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
        fi
        sleep 1
        holders=$(ss -H -lunp 2>/dev/null | awk '$4 ~ /:53$/ {print $0}' | grep -v "masterdnsvpn")
        [[ -z "$holders" ]] && return 0
    fi

    err "May ibang gumagamit pa ng UDP port 53:"
    echo "$holders"
    err "Patayin muna iyon, tapos ulitin."
    return 1
}

open_firewall() {
    local done_fw=0
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow 53/udp >/dev/null 2>&1; ufw allow 53/tcp >/dev/null 2>&1
        ok "ufw: UDP+TCP 53 allowed"; done_fw=1
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --add-port=53/udp --permanent >/dev/null 2>&1
        firewall-cmd --add-port=53/tcp --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1 && ok "firewalld: UDP+TCP 53 allowed"; done_fw=1
    fi
    if [[ $done_fw -eq 0 ]] && command -v iptables >/dev/null 2>&1; then
        local pr
        for pr in udp tcp; do
            iptables -C INPUT -p "$pr" --dport 53 -j ACCEPT 2>/dev/null || iptables -I INPUT -p "$pr" --dport 53 -j ACCEPT
        done
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save >/dev/null 2>&1
        elif command -v iptables-save >/dev/null 2>&1 && [[ -d /etc/iptables ]]; then
            iptables-save > /etc/iptables/rules.v4
        fi
        ok "iptables: UDP+TCP 53 allowed"
    fi
}

# ---------------------------------------------------------------- download

# download_server DIR  -> puts the server binary at $BIN and a sample config in DIR
download_server() {
    local work asset url bin sample
    work=$(mktemp -d) || return 1
    detect_arch || { rm -rf "$work"; return 1; }

    for asset in "MasterDnsVPN_Server_Linux_${ARCH}.zip" "MasterDnsVPN_Server_Linux-Legacy_${ARCH}.zip"; do
        url="${REL_BASE}/${asset}"
        info "Dina-download: ${asset}"
        if ! curl -fL --retry 3 --connect-timeout 15 -o "${work}/pkg.zip" "$url"; then
            warn "Hindi ma-download ang ${asset}"
            continue
        fi
        rm -rf "${work}/x"; mkdir -p "${work}/x"
        unzip -q -o "${work}/pkg.zip" -d "${work}/x" || { warn "Sira ang zip"; continue; }

        bin=$(find "${work}/x" -type f -name 'MasterDnsVPN_Server*' ! -name '*.toml*' ! -name '*.txt' ! -name '*.md' | head -1)
        [[ -z "$bin" ]] && { warn "Walang binary sa ${asset}"; continue; }
        chmod +x "$bin"
        # make sure it actually runs on this system (glibc etc.) before keeping it
        if ! "$bin" -version >/dev/null 2>&1; then
            warn "Hindi tumatakbo ang binary na ito dito, susubukan ang ibang variant..."
            continue
        fi

        mkdir -p "$INSTALL_DIR"
        # stop first so the file isn't "text busy" on update
        systemctl stop "$SERVICE" 2>/dev/null
        install -m 755 "$bin" "$BIN"

        sample=$(find "${work}/x" -type f -name 'server_config.toml*' | head -1)
        if [[ -n "$sample" ]]; then
            cp -f "$sample" "${INSTALL_DIR}/server_config.toml.sample"
        elif ! curl -fsSL -o "${INSTALL_DIR}/server_config.toml.sample" "${RAW_BASE}/server_config.toml.simple"; then
            err "Walang sample config na makuha."
            rm -rf "$work"; return 1
        fi
        rm -rf "$work"
        ok "Na-install ang server binary: $BIN"
        return 0
    done
    rm -rf "$work"
    err "Hindi na-download/na-install ang server. I-check ang internet o i-try ulit."
    return 1
}

write_unit() {
    cat > "$UNIT" <<EOF
[Unit]
Description=MasterDnsVPN Server (DNS Tunnel)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${BIN} -config ${CONF}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

gen_key() { tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${1:-32}"; }

# ---------------------------------------------------------------- actions

do_install() {
    clear
    echo -e "${CYAN}=== Install / Reconfigure MasterDnsVPN ===${NC}"
    echo ""
    echo "Kailangan mo ng SARILING domain na naka-delegate sa VPS na ito:"
    echo "  A  record : ns.example.com  -> IP ng VPS   (DNS only, hindi proxied)"
    echo "  NS record : v.example.com   -> ns.example.com"
    echo "Ang ilalagay dito ay ang tunnel domain (hal. v.example.com)."
    warn "Dapat IBA ito sa domain na ginagamit ng slipstream."
    echo ""

    local cur_dom=""
    is_installed && cur_dom=$(get_toml DOMAIN | tr -d '[]" ')
    local dom
    read -rp "Tunnel domain${cur_dom:+ [$cur_dom]}: " dom
    dom="${dom:-$cur_dom}"
    dom=$(echo "$dom" | tr 'A-Z' 'a-z' | tr -d ' ')
    if ! [[ "$dom" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
        err "Invalid ang domain."
        return 1
    fi

    echo ""
    echo "Encryption method (dapat pareho sa client):"
    echo "  0 None | 1 XOR (mahina) | 2 ChaCha20 (walang auth) | 3 AES-128-GCM | 4 AES-192-GCM | 5 AES-256-GCM"
    local cur_m method
    cur_m=$(get_toml DATA_ENCRYPTION_METHOD); cur_m="${cur_m:-5}"
    read -rp "Method [${cur_m}]: " method
    method="${method:-$cur_m}"
    if ! [[ "$method" =~ ^[0-5]$ ]]; then
        err "Pumili ng 0-5."
        return 1
    fi

    echo ""
    echo "Mode (dapat pareho sa client PROTOCOL_TYPE):"
    echo "  1 = SOCKS5      (para sa AMBER apps: pinipili ng app ang SSH/XRAY/OVPN na target)"
    echo "  2 = TCP -> SSH  (isang fixed na target lang; raw client lang, HINDI gagana sa AMBER apps)"
    local cur_pt cur_mode mode ssh_port cur_fp
    cur_pt=$(get_toml PROTOCOL_TYPE | tr -d '" ')
    cur_mode=1; [[ "$cur_pt" == "TCP" ]] && cur_mode=2
    read -rp "Mode [${cur_mode}]: " mode
    mode="${mode:-$cur_mode}"
    if ! [[ "$mode" =~ ^[12]$ ]]; then
        err "Pumili ng 1 o 2."
        return 1
    fi
    if [[ "$mode" == "2" ]]; then
        cur_fp=$(get_toml FORWARD_PORT | tr -d ' ')
        [[ "$cur_fp" =~ ^[0-9]+$ && "$cur_fp" -gt 0 ]] || cur_fp=$(detect_ssh_port)
        read -rp "SSH port na paglalabasan [${cur_fp}]: " ssh_port
        ssh_port="${ssh_port:-$cur_fp}"
        if ! [[ "$ssh_port" =~ ^[0-9]+$ ]] || (( ssh_port < 1 || ssh_port > 65535 )); then
            err "Invalid na port."
            return 1
        fi
    else
        warn "SOCKS5 = walang login sa tunnel mismo: sinumang may domain+key ay pwedeng gumamit ng server bilang proxy."
        warn "Ang SSH/XRAY/OVPN login pa rin ang proteksyon sa loob; isaalang-alang ang paglilimita ng outbound ng server."
    fi

    ensure_tools || return 1
    free_port_53 || return 1

    if ! is_installed; then
        download_server || return 1
    fi
    [[ -f "${INSTALL_DIR}/server_config.toml.sample" || -f "$CONF" ]] || download_server || return 1

    # fresh config from the upstream sample only the first time; keep tweaks after that
    if [[ ! -f "$CONF" ]]; then
        cp -f "${INSTALL_DIR}/server_config.toml.sample" "$CONF"
    fi

    set_toml DOMAIN "[\"${dom}\"]"
    set_toml DATA_ENCRYPTION_METHOD "$method"
    set_toml ENCRYPTION_KEY_FILE '"encrypt_key.txt"'
    set_toml UDP_PORT 53
    set_toml USE_EXTERNAL_SOCKS5 false
    if [[ "$mode" == "2" ]]; then
        set_toml PROTOCOL_TYPE '"TCP"'
        set_toml FORWARD_IP '"127.0.0.1"'
        set_toml FORWARD_PORT "$ssh_port"
    else
        set_toml PROTOCOL_TYPE '"SOCKS5"'
    fi

    # key length must match the method (32 / 16 / 24) or the server overwrites it.
    # Keep the existing key on reconfigure when it still fits, so clients don't break.
    local need curkey
    need=$(key_len_for "$method")
    curkey=$(tr -d '[:space:]' < "$KEYFILE" 2>/dev/null)
    if [[ ${#curkey} -ne $need ]]; then
        [[ -n "$curkey" ]] && warn "Nagbago ang key length dahil sa method -- bagong key, i-update ang client."
        printf '%s' "$(gen_key "$need")" > "$KEYFILE"
        chmod 600 "$KEYFILE"
        ok "Gumawa ng bagong encryption key (${need} chars)."
    fi

    tune_kernel

    write_unit
    open_firewall
    systemctl enable "$SERVICE" >/dev/null 2>&1
    systemctl restart "$SERVICE"
    sleep 2

    if systemctl is-active --quiet "$SERVICE"; then
        ok "Tumatakbo na ang MasterDnsVPN server."
    else
        err "Hindi nag-start. Tingnan ang log (option Logs)."
        journalctl -u "$SERVICE" -n 15 --no-pager 2>/dev/null
        return 1
    fi
    echo ""
    show_info_body
}

show_info_body() {
    local ip dom method parent pt fport lport
    ip=$(curl -s4 --max-time 8 ifconfig.me 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(wget -qO- ipv4.icanhazip.com 2>/dev/null)
    dom=$(get_toml DOMAIN | tr -d '[]" ')
    method=$(get_toml DATA_ENCRYPTION_METHOD)
    pt=$(get_toml PROTOCOL_TYPE | tr -d '" '); pt="${pt:-SOCKS5}"
    fport=$(get_toml FORWARD_PORT | tr -d ' ')
    parent="${dom#*.}"

    echo -e "${CYAN}----------- MasterDnsVPN INFO -----------${NC}"
    echo -e " Status      : $(svc_state)"
    echo -e " Public IP   : ${ip}"
    echo -e " Domain      : ${dom}"
    echo -e " Method      : ${method}  ($(method_name "$method"))"
    echo -e " Key         : ${GREEN}$(cat "$KEYFILE" 2>/dev/null)${NC}"
    echo -e " UDP port    : 53"
    if [[ "$pt" == "TCP" ]]; then
        echo -e " Mode        : ${YELLOW}TCP -> 127.0.0.1:${fport}${NC} (fixed; HINDI gagana sa AMBER apps)"
    else
        echo -e " Mode        : SOCKS5 (AMBER apps) -- app targets: 22 (SSH), 14018 (XRAY), 1194 (OVPN)"
    fi
    echo ""
    echo -e "${YELLOW}DNS records (sa domain provider mo):${NC}"
    echo "  A   ns.${parent}  ->  ${ip}   (DNS only)"
    echo "  NS  ${dom}  ->  ns.${parent}"
    echo ""
    echo -e "${YELLOW}Sa client (MasterDnsVPN app):${NC}"
    echo "  DOMAINS                = [\"${dom}\"]"
    echo "  ENCRYPTION_KEY         = (ang Key sa itaas)"
    echo "  DATA_ENCRYPTION_METHOD = ${method}"
    echo "  PROTOCOL_TYPE          = \"${pt}\"   (dapat pareho sa server)"
    if [[ "$pt" == "TCP" ]]; then
        echo "  Ikonekta ang SSH client sa 127.0.0.1:LISTEN_PORT ng client (SSH account mo ang login)."
    else
        echo "  XRAY mode sa app ay nangangailangan ng Xray inbound sa 127.0.0.1:14018 (galing sa Slipstream XRAY install)."
    fi
    echo "  Resolvers: maraming working DNS resolvers (hindi lang 8.8.8.8) -- malaki ang epekto sa speed."
    echo -e "${CYAN}-----------------------------------------${NC}"
}

do_info() {
    clear
    if ! is_installed; then warn "Hindi pa naka-install."; return 0; fi
    show_info_body
}

do_restart() {
    if ! is_installed; then warn "Hindi pa naka-install."; return 0; fi
    free_port_53 || return 1
    systemctl restart "$SERVICE" && sleep 1
    systemctl is-active --quiet "$SERVICE" && ok "Restarted." || err "Hindi nag-start. Tingnan ang Logs."
}

do_stop() {
    if ! is_installed; then warn "Hindi pa naka-install."; return 0; fi
    systemctl stop "$SERVICE"; systemctl disable "$SERVICE" >/dev/null 2>&1
    ok "Stopped at naka-disable (hindi mag-a-auto start)."
}

do_update() {
    if ! is_installed; then warn "Hindi pa naka-install. Gamitin ang Install."; return 0; fi
    ensure_tools || return 1
    info "Ina-update ang binary (nananatili ang config at key)..."
    local was_active=0
    systemctl is-active --quiet "$SERVICE" && was_active=1
    if download_server; then
        migrate_config
        tune_kernel
        systemctl enable "$SERVICE" >/dev/null 2>&1
        [[ $was_active -eq 1 ]] && systemctl restart "$SERVICE" || systemctl start "$SERVICE"
        sleep 1
        systemctl is-active --quiet "$SERVICE" && ok "Updated at tumatakbo." || err "Hindi nag-start. Tingnan ang Logs."
    else
        [[ $was_active -eq 1 ]] && systemctl start "$SERVICE"
    fi
}

do_newkey() {
    if ! is_installed; then warn "Hindi pa naka-install."; return 0; fi
    read -rp "Gagawa ng bagong key -- hindi na gagana ang lumang client config. Tuloy? [y/N]: " a
    [[ "$a" =~ ^[Yy]$ ]] || return 0
    printf '%s' "$(gen_key "$(key_len_for "$(get_toml DATA_ENCRYPTION_METHOD)")")" > "$KEYFILE"; chmod 600 "$KEYFILE"
    systemctl restart "$SERVICE"
    ok "Bagong key: $(cat "$KEYFILE")"
}

do_logs() {
    clear
    journalctl -u "$SERVICE" -n 60 --no-pager 2>/dev/null || warn "Walang log."
}

do_uninstall() {
    if [[ ! -f "$UNIT" && ! -d "$INSTALL_DIR" ]]; then warn "Wala namang naka-install."; return 0; fi
    read -rp "Buburahin ang MasterDnsVPN server pati config at key. Tuloy? [y/N]: " a
    [[ "$a" =~ ^[Yy]$ ]] || return 0
    systemctl stop "$SERVICE" 2>/dev/null
    systemctl disable "$SERVICE" >/dev/null 2>&1
    rm -f "$UNIT"
    systemctl daemon-reload
    rm -rf "$INSTALL_DIR"
    remove_tuning
    # note: the systemd-resolved stub drop-in is left alone on purpose, since
    # slipstream's installer also needs port 53 free.
    ok "Na-uninstall."
}

# ---------------------------------------------------------------- menu

show_menu() {
    clear
    echo -e "\e[1;33m -------------------------------------------------\e[0m"
    echo -e "\e[1;34m            MasterDnsVPN (DNS TUNNEL) MENU            \e[0m"
    echo -e "\e[1;33m -------------------------------------------------\e[0m"
    echo -e " Status : $(svc_state)"
    if is_installed; then
        echo -e " Domain : $(get_toml DOMAIN | tr -d '[]" ')"
    fi
    echo -e "\e[1;33m -------------------------------------------------\e[0m"
    echo -e "\e[1;36m 1 \e[0m: Install / Reconfigure"
    echo -e "\e[1;36m 2 \e[0m: Show Info (domain, key, DNS records)"
    echo -e "\e[1;36m 3 \e[0m: Restart"
    echo -e "\e[1;36m 4 \e[0m: Stop & Disable"
    echo -e "\e[1;36m 5 \e[0m: Update server binary"
    echo -e "\e[1;36m 6 \e[0m: Generate new key"
    echo -e "\e[1;36m 7 \e[0m: Logs"
    echo -e "\e[1;36m 8 \e[0m: Uninstall"
    echo -e "\e[1;36m 9 \e[0m: Apply kernel tuning (UDP buffer) + restart"
    echo -e "\e[1;36m 0 \e[0m: Back to main menu"
    echo -e "\e[1;33m -------------------------------------------------\e[0m"
    read -rp " Select menu : " opt
    echo ""
    case "$opt" in
        1) do_install; pause ;;
        2) do_info; pause ;;
        3) do_restart; pause ;;
        4) do_stop; pause ;;
        5) do_update; pause ;;
        6) do_newkey; pause ;;
        7) do_logs; pause ;;
        8) do_uninstall; pause ;;
        9) do_tune; pause ;;
        0|x) exit 0 ;;
        *) echo "Invalid selection"; sleep 1 ;;
    esac
}

while true; do
    show_menu
done

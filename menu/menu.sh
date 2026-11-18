#!/bin/bash

# Function to fetch RAM information
get_ram_info() {
    ram_info=$(free -m | awk 'NR==2{print $2,$3}')
    tram=$(echo "$ram_info" | awk '{print $1}')
    uram=$(echo "$ram_info" | awk '{print $2}')
}

# Function to fetch CPU usage information
get_cpu_usage() {
    cpu_usage=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
    cpu_usage=$(echo "$cpu_usage" | awk '{printf "%.2f", $1}')
    cpu_usage+=" %"
}

# Function to display VPS information
show_vps_info() {
    clear
    # Self-heal DNS if resolv.conf is broken (e.g. systemd-resolved disabled)
    if ! getent hosts api.country.is >/dev/null 2>&1; then
        chattr -i /etc/resolv.conf 2>/dev/null
        rm -f /etc/resolv.conf
        printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf
        chattr +i /etc/resolv.conf 2>/dev/null
    fi
    domain=$(cat /etc/xray/domain)
    uptime=$(uptime -p | cut -d " " -f 2-10)
    DATE2=$(date -R | cut -d " " -f -5)
    IPVPS=$(curl -s ifconfig.me)
    LOC=$(curl -sS "https://api.country.is/${IPVPS}" | jq -r '.country')
    if [ -z "$LOC" ]; then
        LOC="Unknown"
    fi

    echo -e "\e[1;33m -------------------------------------------------\e[0m"
    echo -e "\e[1;34m                     AMBER VPN VIP SCRIPT                   \e[0m"
    echo -e "\e[1;33m -------------------------------------------------\e[0m"
    echo -e "\e[1;32m OS            \e[0m: $(hostnamectl | grep "Operating System" | cut -d ' ' -f5-)"
    echo -e "\e[1;32m Uptime        \e[0m: $uptime"
    echo -e "\e[1;32m Public IP     \e[0m: $IPVPS"
    echo -e "\e[1;32m Country       \e[0m: $LOC"
    echo -e "\e[1;32m DOMAIN        \e[0m: $domain"
    echo -e "\e[1;32m DATE & TIME   \e[0m: $DATE2"
    echo -e "\e[1;33m -------------------------------------------------\e[0m"
}

# Function to display CPU and RAM information
show_cpu_ram_info() {
    get_ram_info
    get_cpu_usage

    echo -e "\e[1;34m                   AMBER VPN CPU/RAM INFO                  \e[0m"
    echo -e "\e[1;33m -------------------------------------------------\e[0m"
    echo -e "\e[1;32m CPU USAGE   \e[0m: $cpu_usage"
    echo -e "\e[1;32m RAM USED    \e[0m: ${uram} MB"
    echo -e "\e[1;32m RAM TOTAL   \e[0m: ${tram} MB"
    echo -e "\e[1;33m -------------------------------------------------\e[0m"
}

# Function to display menu and handle user input
show_menu() {
    show_vps_info
    show_cpu_ram_info

    echo -e "\e[1;34m                      AMBER VPN MENU                       \e[0m"
    echo -e "\e[1;33m -------------------------------------------------\e[0m"
    echo -e ""
    echo -e "\e[1;36m 1 \e[0m: Menu SSH"
    echo -e "\e[1;36m 2 \e[0m: Menu Vless"
    echo -e "\e[1;36m 3 \e[0m: Menu Vmess"
    echo -e "\e[1;36m 4 \e[0m: Menu Trojan"
    echo -e "\e[1;36m 5 \e[0m: Menu Slipstream (DNS Tunnel)"
    echo -e "\e[1;36m 6 \e[0m: Menu VayDNS (DNS Tunnel)"
    echo -e "\e[1;36m 7 \e[0m: Menu Soar (DNS Tunnel)"
    echo -e "\e[1;36m 8 \e[0m: Menu Pingtunnel (ICMP Tunnel)"
    echo -e "\e[1;36m 9 \e[0m: Menu L2TP/IPsec"
    echo -e "\e[1;36m 10 \e[0m: Menu Setting"
    echo -e "\e[1;36m 11 \e[0m: Status Service"
    echo -e "\e[1;36m 12 \e[0m: Reboot VPS"
    echo -e "\e[1;36m x \e[0m: Exit Script"
    echo -e ""
    echo -e "\e[1;33m -------------------------------------------------\e[0m"
    echo -e "\e[1;32m Client Name \e[0m: $Name"
    echo -e "\e[1;32m Expired     \e[0m: $Exp2"
    echo -e "\e[1;32m SCRIPT BY   \e[0m: AMBER VPN"
    echo -e "\e[1;32m Telegram    \e[0m: https://t.me/AMBER1432"
    echo -e "\e[1;33m -------------------------------------------------\e[0m"
    echo -e ""
    read -p " Select menu :  " opt
    echo ""
    case $opt in
    1) clear ; m-sshovpn ;;
    2) clear ; m-vless ;;
    3) clear ; m-vmess ;;
    4) clear ; m-trojan ;;
    5) clear ; slipstream-rust-deploy ;;
    6) clear ; vaydns-deploy ;;
    7) clear ; soar-deploy ;;
    8) clear ; pingtunnel-deploy ;;
    9) clear ; l2tp-deploy ;;
    10) clear ; m-system ;;
    11) clear ; running ;;
    12) clear ; /sbin/reboot ;;
    x) exit ;;
    *) echo "Invalid selection" ; sleep 1 ;;
    esac
}

# Initial setup
Exp2="LIFETIME"
Name="AMBER VPN"

# Main loop to display menu continuously
while true; do
    show_menu
done

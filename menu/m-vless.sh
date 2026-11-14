#!/bin/bash
MYIP=$(wget -qO- ipv4.icanhazip.com);
echo "Checking VPS"
clear
echo -e "\e[33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "\e[33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e ""
echo -e " [\e[36m•1\e[0m] Create Account Vless "
echo -e " [\e[36m•2\e[0m] Create Account Vless XHTTP "
echo -e " [\e[36m•3\e[0m] View Account Vless "
echo -e " [\e[36m•4\e[0m] Delete Account Vless "
echo -e ""
echo -e " [\e[31m•0\e[0m] \e[31mBACK TO SENSI MENU\033[0m"
echo -e ""
echo -e   "Press x or [ Ctrl+C ] • To-Exit"
echo ""
echo -e "\e[33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e ""
read -p " Select menu :  "  opt
echo -e ""
case $opt in
1) clear ; add-vless ; exit ;;
2) clear ; add-vless-http ; exit ;;
3) clear ; view-acc vless ; exit ;;
4) clear ; del-vless ; exit ;;
0) clear ; menu ; exit ;;
x) exit ;;
esac

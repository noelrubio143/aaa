#!/bin/bash

MYIP=$(wget -qO- ipv4.icanhazip.com);
echo "Checking VPS"
clear
echo -e "
"
date
echo ""
botak=$(cat /etc/xray/domain 2>/dev/null || cat /root/domain 2>/dev/null || wget -qO- ipv4.icanhazip.com)
mkdir -p /etc/xray
echo "$botak" > /etc/xray/domain
echo "$botak" > /root/domain
domain=$(cat /root/domain)
sleep 0.5
echo -e "[ INFO ] Checking... "
apt install iptables iptables-persistent -y
sleep 0.5
echo -e "[ INFO ] Setting time sync"
# ntpdate is gone (transitional-at-best) on Debian 13 / newer Ubuntu, so
# skip it -- timedatectl/chrony below already handle syncing the clock.
timedatectl set-ntp true
sleep 0.5
echo -e "[ INFO ] Enable chrony"
apt -y install chrony
systemctl enable chrony
systemctl restart chrony
timedatectl set-timezone Asia/Jakarta
sleep 0.5
echo -e "[ INFO ] Setting chrony tracking"
chronyc sourcestats -v
chronyc tracking -v
echo -e "[ INFO ] Setting dll"
apt clean all && apt update
apt install -y curl wget xz-utils apt-transport-https gnupg lsb-release openssl cron unzip


# install xray
sleep 0.5
echo -e "[ INFO ] Downloading & Installing xray core"
domainSock_dir="/run/xray";! [ -d $domainSock_dir ] && mkdir  $domainSock_dir
chown www-data.www-data $domainSock_dir
# Make Folder XRay
mkdir -p /var/log/xray
mkdir -p /etc/xray
chown www-data.www-data /var/log/xray
chmod +x /var/log/xray
touch /var/log/xray/error.log
touch /var/log/xray/error2.log
# logs were just created as root; xray runs as www-data (formerly done by install-release.sh)
chown -R www-data:www-data /var/log/xray
# / / Ambil Xray Core Version Terbaru
# Pull the compiled xray-core zip from our own GitLab mirror (no GitHub
# dependency at all). The zip is unpacked by hand: this script already writes
# its own xray.service and /etc/xray/config.json, so all we need from the
# zip is the xray binary at /usr/local/bin/xray.
XRAY_ZIP_URL="https://gitlab.com/-/project/84844354/uploads/63447f3c56cb1cb1177ab4f4ef2f3f2a/Xray-linux-64.zip"
XRAY_ZIP_LOCAL="/tmp/Xray-linux-64.zip"
XRAY_TMP_DIR="/tmp/xray-extract"

echo -e "[ INFO ] Downloading xray-core from GitLab mirror..."
wget -q -O "$XRAY_ZIP_LOCAL" "$XRAY_ZIP_URL"

echo -e "[ OK ] Installing xray-core from GitLab mirror"
rm -rf "$XRAY_TMP_DIR" && mkdir -p "$XRAY_TMP_DIR"
if ! unzip -o -q "$XRAY_ZIP_LOCAL" xray -d "$XRAY_TMP_DIR" || [ ! -f "$XRAY_TMP_DIR/xray" ]; then
    echo -e "[ ERROR ] Failed to extract xray from $XRAY_ZIP_LOCAL (bad/corrupt download?)"
    exit 1
fi
systemctl stop xray 2>/dev/null || true
install -m 755 "$XRAY_TMP_DIR/xray" /usr/local/bin/xray
rm -rf "$XRAY_ZIP_LOCAL" "$XRAY_TMP_DIR"

## crt xray: self-signed sa IP (ginagawa ng setup1.sh / m-ssl -> /etc/xray/xray.crt + xray.key)
mkdir -p /etc/xray

mkdir -p /home/vps/public_html

# set uuid
uuid=$(cat /proc/sys/kernel/random/uuid)
# xray config
cat > /etc/xray/config.json << END
{
  "log" : {
    "access": "none",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
      {
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      },
      "tag": "api"
    },
   {
     "listen": "127.0.0.1",
     "port": "14016",
     "protocol": "vless",
      "settings": {
          "decryption":"none",
            "clients": [
               {
                 "id": "${uuid}"                 
#vless
             }
          ]
       },
       "streamSettings":{
         "network": "ws",
            "wsSettings": {
                "path": "/vless"
          }
        }
     },
     {
     "listen": "127.0.0.1",
     "port": "23456",
     "protocol": "vmess",
      "settings": {
            "clients": [
               {
                 "id": "${uuid}",
                 "alterId": 0
#vmess
             }
          ]
       },
       "streamSettings":{
         "network": "ws",
            "wsSettings": {
                "path": "/vmess"
          }
        }
     },
    {
      "listen": "127.0.0.1",
      "port": "25432",
      "protocol": "trojan",
      "settings": {
          "decryption":"none",		
           "clients": [
              {
                 "password": "${uuid}"
#trojanws
              }
          ],
         "udp": true
       },
       "streamSettings":{
           "network": "ws",
           "wsSettings": {
               "path": "/trojan-ws"
            }
         }
     },
    {
      "listen": "127.0.0.1",
      "port": 14017,
      "protocol": "vless",
      "tag": "xhttp-vless",
      "settings": {
        "decryption": "none",
        "clients": [
          {
            "id": "${uuid}"
#vlessxhttp
          }
        ]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "path": "/xhttp-vless",
          "mode": "auto"
        }
      }
    },
    {
      "listen": "127.0.0.1",
      "port": 23457,
      "protocol": "vmess",
      "tag": "xhttp-vmess",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "alterId": 0
#vmessxhttp
          }
        ]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "path": "/xhttp-vmess",
          "mode": "auto"
        }
      }
    },
    {
      "listen": "127.0.0.1",
      "port": 25433,
      "protocol": "trojan",
      "tag": "xhttp-trojan",
      "settings": {
        "clients": [
          {
            "password": "${uuid}"
#trojanxhttp
          }
        ]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "path": "/xhttp-trojan",
          "mode": "auto"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "blocked"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "ip": [
          "0.0.0.0/8",
          "10.0.0.0/8",
          "100.64.0.0/10",
          "169.254.0.0/16",
          "172.16.0.0/12",
          "192.0.0.0/24",
          "192.0.2.0/24",
          "192.168.0.0/16",
          "198.18.0.0/15",
          "198.51.100.0/24",
          "203.0.113.0/24",
          "::1/128",
          "fc00::/7",
          "fe80::/10"
        ],
        "outboundTag": "blocked"
      },
      {
        "inboundTag": [
          "api"
        ],
        "outboundTag": "api",
        "type": "field"
      },
      {
        "type": "field",
        "outboundTag": "blocked",
        "protocol": [
          "bittorrent"
        ]
      }
    ]
  },
  "stats": {},
  "api": {
    "services": [
      "StatsService"
    ],
    "tag": "api"
  },
  "policy": {
    "levels": {
      "0": {
        "statsUserDownlink": true,
        "statsUserUplink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink" : true,
      "statsOutboundDownlink" : true
    }
  }
}
END
rm -rf /etc/systemd/system/xray.service.d
rm -rf /etc/systemd/system/xray@.service
cat <<EOF> /etc/systemd/system/xray.service
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=www-data
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target

EOF
cat > /etc/systemd/system/runn.service <<EOF
[Unit]
Description=Mantap-Sayang
After=network.target

[Service]
Type=simple
ExecStartPre=-/usr/bin/mkdir -p /var/run/xray
ExecStart=/usr/bin/chown www-data:www-data /var/run/xray
Restart=on-abort

[Install]
WantedBy=multi-user.target
EOF

echo "[SERVICE] Restart All service"
systemctl daemon-reload
sleep 0.5
echo "[ ok ] Enable & restart xray "
systemctl daemon-reload
systemctl enable xray
systemctl restart xray
systemctl enable runn
systemctl restart runn

cd /usr/bin/
# vless
wget -O add-vless "https://gitlab.com/babayega143/aaa/-/raw/main/xray/add-vless.sh" && chmod +x add-vless
wget -O del-vless "https://gitlab.com/babayega143/aaa/-/raw/main/xray/del-vless.sh" && chmod +x del-vless

# vmess
wget -O add-ws "https://gitlab.com/babayega143/aaa/-/raw/main/xray/add-ws.sh" && chmod +x add-ws
wget -O del-ws "https://gitlab.com/babayega143/aaa/-/raw/main/xray/del-ws.sh" && chmod +x del-ws

# trojan
wget -O add-tr "https://gitlab.com/babayega143/aaa/-/raw/main/xray/add-tr.sh" && chmod +x add-tr
wget -O del-tr "https://gitlab.com/babayega143/aaa/-/raw/main/xray/del-tr.sh" && chmod +x del-tr



# XHTTP account creators (inbounds are set up above; HTTP routing lives in gomux)
wget -O add-vless-http "https://gitlab.com/babayega143/aaa/-/raw/main/xray/add-vless-http.sh" && chmod +x add-vless-http
wget -O add-http "https://gitlab.com/babayega143/aaa/-/raw/main/xray/add-http.sh" && chmod +x add-http
wget -O add-trojan-http "https://gitlab.com/babayega143/aaa/-/raw/main/xray/add-trojan-http.sh" && chmod +x add-trojan-http

# View an existing account again (vless / vmess / trojan, WS + XHTTP)
wget -O view-acc "https://gitlab.com/babayega143/aaa/-/raw/main/xray/view-acc.sh" && chmod +x view-acc

sleep 0.5
yellow() { echo -e "\\033[33;1m${*}\\033[0m"; }
yellow "xray/Vmess"
yellow "xray/Vless"

mv /root/domain /etc/xray/ 
if [ -f /root/scdomain ];then
rm /root/scdomain > /dev/null 2>&1
fi
clear
rm -f ins-xray.sh  

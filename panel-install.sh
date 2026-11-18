#!/bin/bash
# Install / UPDATE the public trial panel on an existing aaa-main VPS. Run as root.
# Re-running this script = update (keeps your port). Usage: bash panel-install.sh [port]
RAW="https://raw.githubusercontent.com/noelrubio143/aaa/main"
DIR=/opt/trial-portal
SVC=/etc/systemd/system/trial-portal.service
[ "$(id -u)" = 0 ] || { echo "Run as root"; exit 1; }
[ -f /etc/xray/config.json ] || { echo "Install aaa-main first (setup1.sh) - /etc/xray/config.json not found"; exit 1; }
OLD=$(grep -oP 'Environment=PORT=\K[0-9]+' $SVC 2>/dev/null)
PORT="${1:-${OLD:-8090}}"
command -v python3 >/dev/null || apt-get install -y python3
mkdir -p $DIR
wget -q -O $DIR/server.py.new $RAW/server.py && wget -q -O $DIR/panel.html.new $RAW/panel.html \
  || { echo "Download failed"; rm -f $DIR/*.new; exit 1; }
sed -i 's/\r$//' $DIR/server.py.new $DIR/panel.html.new
python3 -m py_compile $DIR/server.py.new || { echo "server.py has errors"; exit 1; }
mv $DIR/server.py.new $DIR/server.py; mv $DIR/panel.html.new $DIR/panel.html; rm -f $DIR/index.html
cat > $SVC <<EOT
[Unit]
Description=Public trial panel
After=network.target

[Service]
Environment=BIND=0.0.0.0
Environment=PORT=$PORT
ExecStart=/usr/bin/python3 $DIR/server.py
Restart=always

[Install]
WantedBy=multi-user.target
EOT
iptables -C INPUT -p tcp --dport $PORT -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport $PORT -j ACCEPT 2>/dev/null
systemctl daemon-reload
systemctl enable trial-portal >/dev/null 2>&1
systemctl restart trial-portal
sleep 1
if systemctl is-active --quiet trial-portal; then
  dom=$(cat /etc/xray/domain 2>/dev/null); [ -z "$dom" ] && dom=$(wget -qO- ipv4.icanhazip.com)
  echo "Panel is running."
  echo "Panel link: http://$dom:$PORT"
  echo ""
  echo "Para lumabas sa Pages list mo, idagdag ito sa servers.json (GitHub):"
  echo "  {\"name\": \"$(hostname)\", \"host\": \"$dom\"}"
else
  echo "Panel failed to start:  journalctl -u trial-portal -e"
fi

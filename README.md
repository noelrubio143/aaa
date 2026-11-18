```
apt update && apt upgrade -y && reboot
```


#[Step Install]
```
apt update && apt install -y bzip2 gzip coreutils screen curl unzip && wget https://raw.githubusercontent.com/noelrubio143/aaa/main/setup1.sh && chmod +x setup1.sh && sed -i -e 's/\r$//' setup1.sh && screen -S setup ./setup1.sh
```


#[Public Trial Panel]
Public page kung saan kahit sino puwedeng gumawa ng trial account (SSH, OVPN, VMess, VLESS, Trojan), 3 days ang bawat account. Sila lang ang nakakakita at nakakapag-delete ng account nila.

**Install / Update sa VPS** (patakbuhin bilang root; ito rin ang gamitin sa bawat update ng panel):
```
wget -O panel-install.sh https://raw.githubusercontent.com/noelrubio143/aaa/main/panel-install.sh && sed -i -e 's/\r$//' panel-install.sh && bash panel-install.sh
```

**Panel link:** https://noelrubio143.github.io/aaa/

(GitHub Pages ang launcher; ilalagay mo roon ang domain ng VPS at bubuksan nito ang tunay na panel sa `http://YOUR-DOMAIN:8090`. Ipinapakita rin ng installer ang direktang link pagkatapos mag-install. Para isang tap na lang, ilagay ang domain mo sa `DEFAULT_HOST` sa loob ng `index.html`, o gamitin ang `https://noelrubio143.github.io/aaa/?h=YOUR-DOMAIN`.)

Iba ang port kung gusto mo: `bash panel-install.sh 8091` (huwag 8080, gamit iyon ng Squid).

Mga command:
```
systemctl status trial-portal      # check kung tumatakbo
journalctl -u trial-portal -e      # logs
systemctl restart trial-portal     # restart
```
Options (sa `/etc/systemd/system/trial-portal.service`, magdagdag ng `Environment=`): `TRIAL_HOURS=72` `MAX_ACTIVE=0` (0 = unlimited) `PER_IP_LIMIT=0` `RATE_PER_MIN=20`. Pagkatapos: `systemctl daemon-reload && systemctl restart trial-portal`.

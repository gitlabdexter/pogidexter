#!/usr/bin/env bash
# Quick Setup | Script Setup Manager (Debian 12 compatible)
# Edition : Stable Edition 1.0 - adapted for Debian 12
# Author  : givps (adapted)
# License : MIT
set -euo pipefail

# Noninteractive APT
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

log() { echo "$(date -Is) $*"; }

log "Detecting public IP"
if command -v curl >/dev/null 2>&1; then
  MYIP=$(curl -fsSL ipv4.icanhazip.com || true)
else
  MYIP=$(wget -qO- ipv4.icanhazip.com || true)
fi
: "${MYIP:=127.0.0.1}"
MYIP2="s/xxxxxxxxx/${MYIP}/g"

NET=$(ip -o -4 route show to default | awk '{print $5}' | head -n1 || true)

if [ -r /etc/os-release ]; then
  source /etc/os-release
  ver=${VERSION_ID:-}
else
  ver=""
fi

log "Platform: ${PRETTY_NAME:-Unknown}; Version: ${ver:-unknown}; Interface: ${NET}; IP: ${MYIP}"

log "Updating apt cache and upgrading system"
apt update -y
apt -y full-upgrade

log "Removing ufw firewalld and exim4 if present"
apt-get remove --purge -y ufw firewalld exim4 || true

log "Installing required packages"
apt-get update -y
apt-get install -y --no-install-recommends netfilter-persistent screen curl jq bzip2 gzip vnstat coreutils rsyslog iftop zip unzip git apt-transport-https build-essential wget openssl ca-certificates figlet ruby python3 python3-venv python3-pip make cmake rsyslog net-tools nano sed gnupg bc jq dirmngr libxml-parser-perl neofetch lsof libsqlite3-dev zlib1g-dev libssl-dev dos2unix gcc g++ libreadline-dev perl

if ! command -v shc >/dev/null 2>&1; then
  log "Installing shc"
  apt-get install -y shc || log "shc not available via apt skip"
fi

if command -v gem >/dev/null 2>&1; then
  log "Installing lolcat gem"
  gem install lolcat || log "gem install lolcat failed continue"
fi

if [ -z "${NET}" ]; then
  NET=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)
fi

PAM_BACKUP=/etc/pam.d/common-password.bak-$(date +%s)
if [ -f /etc/pam.d/common-password ]; then
  log "Backing up existing /etc/pam.d/common-password to ${PAM_BACKUP}"
  cp -a /etc/pam.d/common-password "${PAM_BACKUP}"
fi

: '
echo "Retrieving encrypted PAM file and decrypting (UNCOMMENT to enable)..."
curl -sS https://raw.githubusercontent.com/gitlabdexter/pogidexter/refs/heads/server_script/ssh/password | openssl aes-256-cbc -d -a -pass pass:scvps07gg -pbkdf2 > /etc/pam.d/common-password
chmod 644 /etc/pam.d/common-password
'

log "Installing rc.local shim"
cat > /etc/systemd/system/rc-local.service <<'EOF'
[Unit]
Description=/etc/rc.local
ConditionPathExists=/etc/rc.local
[Service]
Type=forking
ExecStart=/etc/rc.local start
TimeoutSec=0
StandardOutput=tty
RemainAfterExit=yes
SysVStartPriority=99
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/rc.local <<'EOF'
#!/bin/sh -e
exit 0
EOF

chmod +x /etc/rc.local
systemctl daemon-reload
systemctl enable --now rc-local.service || true

log "Disabling IPv6 persistently"
cat > /etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
# Disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
sysctl --system || true

log "Housekeeping apt"
apt-get -y autoremove
apt-get -y clean

log "Set timezone to Asia/Jakarta"
ln -fs /usr/share/zoneinfo/Asia/Jakarta /etc/localtime

log "Comment AcceptEnv lines in sshd_config"
sed -i 's/AcceptEnv/#AcceptEnv/g' /etc/ssh/sshd_config || true

install_ssl(){
    if [ -f "/usr/bin/apt-get" ];then
            isDebian=$(cat /etc/issue | grep Debian || true)
            apt-get install -y nginx certbot || true
            apt install -y nginx certbot || true
            sleep 3
    else
            yum install -y nginx certbot || true
            sleep 3
    fi

    systemctl stop nginx.service || true

    if [ -f "/usr/bin/apt-get" ];then
            isDebian=$(cat /etc/issue | grep Debian || true)
            echo "A" | certbot certonly --renew-by-default --register-unsafely-without-email --standalone -d $domain || true
            sleep 3
    else
        echo "Y" | certbot certonly --renew-by-default --register-unsafely-without-email --standalone -d $domain || true
        sleep 3
    fi
}

log "Installing nginx and web files"
apt -y install nginx
cd
rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/sites-available/default
wget -O /etc/nginx/nginx.conf "https://raw.githubusercontent.com/gitlabdexter/pogidexter/refs/heads/server_script/ssh/nginx.conf"
rm -f /etc/nginx/conf.d/vps.conf
wget -O /etc/nginx/conf.d/vps.conf "https://raw.githubusercontent.com/gitlabdexter/pogidexter/refs/heads/server_script/ssh/vps.conf"
systemctl restart nginx || true

mkdir -p /etc/systemd/system/nginx.service.d
cat > /etc/systemd/system/nginx.service.d/override.conf <<'EOF'
[Service]
ExecStartPost=/bin/sleep 0.1
EOF
rm -f /etc/nginx/conf.d/default.conf
systemctl daemon-reload
systemctl restart nginx || true
cd
mkdir -p /home/vps/public_html
wget -O /home/vps/public_html/index.html "https://raw.githubusercontent.com/gitlabdexter/pogidexter/refs/heads/server_script/ssh/index"
mkdir -p /home/vps/public_html/ss-ws
mkdir -p /home/vps/public_html/clash-ws

 wget --no-check-certificate -O /etc/init.d/squid https://gitlab.com/dextereskalarte/Mtk-dev/-/raw/main/squid.sh
    chmod +x /etc/init.d/squid
    update-rc.d squid defaults
    chown -cR proxy /var/log/squid
    squid -z
    cd /etc/squid/
    rm squid.conf
    echo "acl Firenet dst `curl -s https://api.ipify.org`" >> squid.conf
    echo 'http_port 8080
http_port 8181
visible_hostname Proxy
acl PURGE method PURGE
acl HEAD method HEAD
acl POST method POST
acl GET method GET
acl CONNECT method CONNECT
http_access allow Firenet
http_reply_access allow all
http_access deny all
icp_access allow all
always_direct allow all
visible_hostname Dexter-Proxy
error_directory /usr/share/squid/errors/English' >> squid.conf
    cd /usr/share/squid/errors/English
    rm ERR_INVALID_URL
    echo '<!--MtkDev--><!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>SECURE PROXY</title><meta name="viewport" content="width=device-width, initial-scale=1"><meta http-equiv="X-UA-Compatible" content="IE=edge"/><link rel="stylesheet" href="https://bootswatch.com/4/slate/bootstrap.min.css" media="screen"><link href="https://fonts.googleapis.com/css?family=Press+Start+2P" rel="stylesheet"><style>body{font-family: "Press Start 2P", cursive;}.fn-color{color: #ffff; background-image: -webkit-linear-gradient(92deg, #f35626, #feab3a); -webkit-background-clip: text; -webkit-text-fill-color: transparent; -webkit-animation: hue 5s infinite linear;}@-webkit-keyframes hue{from{-webkit-filter: hue-rotate(0deg);}to{-webkit-filter: hue-rotate(-360deg);}}</style></head><body><div class="container" style="padding-top: 50px"><div class="jumbotron"><h1 class="display-3 text-center fn-color">SECURE PROXY</h1><h4 class="text-center text-danger">SERVER</h4><p class="text-center">😍 %w 😍</p></div></div></body></html>' >> ERR_INVALID_URL
    chmod 755 *
    /etc/init.d/squid start
cd /etc || exit
rm /etc/apt/sources.list
sudo cp /etc/apt/sources.list_backup /etc/apt/sources.list

log "Installing badvpn binary"
cd
wget -O /usr/bin/badvpn-udpgw "https://raw.githubusercontent.com/gitlabdexter/pogidexter/refs/heads/server_script/ssh/newudpgw"
chmod +x /usr/bin/badvpn-udpgw

echo "screen -dmS badvpn badvpn-udpgw --listen-addr 127.0.0.1:7100 --max-clients 500" >> /etc/rc.local
echo "screen -dmS badvpn badvpn-udpgw --listen-addr 127.0.0.1:7200 --max-clients 500" >> /etc/rc.local
echo "screen -dmS badvpn badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 500" >> /etc/rc.local
echo "screen -dmS badvpn badvpn-udpgw --listen-addr 127.0.0.1:7400 --max-clients 500" >> /etc/rc.local
echo "screen -dmS badvpn badvpn-udpgw --listen-addr 127.0.0.1:7500 --max-clients 500" >> /etc/rc.local
echo "screen -dmS badvpn badvpn-udpgw --listen-addr 127.0.0.1:7600 --max-clients 500" >> /etc/rc.local
echo "screen -dmS badvpn badvpn-udpgw --listen-addr 127.0.0.1:7700 --max-clients 500" >> /etc/rc.local
echo "screen -dmS badvpn badvpn-udpgw --listen-addr 127.0.0.1:7800 --max-clients 500" >> /etc/rc.local
echo "screen -dmS badvpn badvpn-udpgw --listen-addr 127.0.0.1:7900 --max-clients 500" >> /etc/rc.local

screen -dmS badvpn badvpn-udpgw --listen-addr 127.0.0.1:7100 --max-clients 500
screen -dmS badvpn badvpn-udpgw --listen-addr 127.0.0.1:7200 --max-clients 500
screen -dmS badvpn badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 500
screen -dmS badvpn badvpn-udpgw --listen-addr 127.0.0.1:7400 --max-clients 500
screen -dmS badvpn badvpn-udpgw --listen-addr 127.0.0.1:7500 --max-clients 500
screen -dmS badvpn badvpn-udpgw --listen-addr 127.0.0.1:7600 --max-clients 500
screen -dmS badvpn badvpn-udpgw --listen-addr 127.0.0.1:7700 --max-clients 500
screen -dmS badvpn badvpn-udpgw --listen-addr 127.0.0.1:7800 --max-clients 500
screen -dmS badvpn badvpn-udpgw --listen-addr 127.0.0.1:7900 --max-clients 500

log "Configuring SSH ports"
cd
sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config
grep -q "^Port 500$" /etc/ssh/sshd_config || echo "Port 500" >> /etc/ssh/sshd_config
grep -q "^Port 40000$" /etc/ssh/sshd_config || echo "Port 40000" >> /etc/ssh/sshd_config
grep -q "^Port 81$" /etc/ssh/sshd_config || echo "Port 81" >> /etc/ssh/sshd_config
grep -q "^Port 51443$" /etc/ssh/sshd_config || echo "Port 51443" >> /etc/ssh/sshd_config
grep -q "^Port 58080$" /etc/ssh/sshd_config || echo "Port 58080" >> /etc/ssh/sshd_config
grep -q "^Port 666$" /etc/ssh/sshd_config || echo "Port 666" >> /etc/ssh/sshd_config
grep -q "^Port 200$" /etc/ssh/sshd_config || echo "Port 200" >> /etc/ssh/sshd_config
grep -q "^Port 22$" /etc/ssh/sshd_config || echo "Port 22" >> /etc/ssh/sshd_config
grep -q "^Port 2222$" /etc/ssh/sshd_config || echo "Port 2222" >> /etc/ssh/sshd_config
grep -q "^Port 2269$" /etc/ssh/sshd_config || echo "Port 2269" >> /etc/ssh/sshd_config
systemctl restart ssh || true

log "Install and configure Dropbear"
apt -y install dropbear
sed -i 's/NO_START=1/NO_START=0/g' /etc/default/dropbear || true
sed -i 's/DROPBEAR_PORT=22/DROPBEAR_PORT=143/g' /etc/default/dropbear || true
sed -i 's/DROPBEAR_EXTRA_ARGS=/DROPBEAR_EXTRA_ARGS="-p 50000 -p 109 -p 110 -p 69"/g' /etc/default/dropbear || true
grep -q "/bin/false" /etc/shells || echo "/bin/false" >> /etc/shells
grep -q "/usr/sbin/nologin" /etc/shells || echo "/usr/sbin/nologin" >> /etc/shells
systemctl restart ssh || true
systemctl restart dropbear || true

cd
log "Install stunnel"
apt install -y stunnel4
cat > /etc/stunnel/stunnel.conf <<'EOF'
cert = /etc/stunnel/stunnel.pem
client = no
socket = a:SO_REUSEADDR=1
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

[dropbear]
accept = 222
connect = 127.0.0.1:22

[dropbear]
accept = 777
connect = 127.0.0.1:109

[ws-stunnel]
accept = 2096
connect = 700

EOF

log "Generate stunnel certificate"
openssl genrsa -out key.pem 2048
openssl req -new -x509 -key key.pem -out cert.pem -days 1095 -subj "/C=$country/ST=$state/L=$locality/O=$organization/OU=$organizationalunit/CN=$commonname/emailAddress=$email"
cat key.pem cert.pem >> /etc/stunnel/stunnel.pem

sed -i 's/ENABLED=0/ENABLED=1/g' /etc/default/stunnel4 || true
systemctl enable --now stunnel4 || true
systemctl restart stunnel4 || true

log "Install fail2ban"
apt -y install fail2ban

log "Installing DOS-Deflate if not present"
if [ -d '/usr/local/ddos' ]; then
  echo "Please un-install the previous version first"
else
  mkdir -p /usr/local/ddos
  wget -q -O /usr/local/ddos/ddos.conf http://www.inetbase.com/scripts/ddos/ddos.conf || true
  wget -q -O /usr/local/ddos/LICENSE http://www.inetbase.com/scripts/ddos/LICENSE || true
  wget -q -O /usr/local/ddos/ignore.ip.list http://www.inetbase.com/scripts/ddos/ignore.ip.list || true
  wget -q -O /usr/local/ddos/ddos.sh http://www.inetbase.com/scripts/ddos/ddos.sh || true
  chmod 0755 /usr/local/ddos/ddos.sh || true
  cp -s /usr/local/ddos/ddos.sh /usr/local/sbin/ddos || true
  /usr/local/ddos/ddos.sh --cron > /dev/null 2>&1 || true
fi

log "Download banner and set"
wget -O /etc/issue.net "https://raw.githubusercontent.com/gitlabdexter/pogidexter/refs/heads/server_script/ssh/banner.conf"
grep -q "Banner /etc/issue.net" /etc/ssh/sshd_config || echo "Banner /etc/issue.net" >> /etc/ssh/sshd_config
sed -i 's@DROPBEAR_BANNER=""@DROPBEAR_BANNER="/etc/issue.net"@g' /etc/default/dropbear || true

log "Blocking torrent strings using iptables compatibility"
iptables -A FORWARD -m string --string "get_peers" --algo bm -j DROP || true
iptables -A FORWARD -m string --string "announce_peer" --algo bm -j DROP || true
iptables -A FORWARD -m string --string "find_node" --algo bm -j DROP || true
iptables -A FORWARD -m string --algo bm --string "BitTorrent" -j DROP || true
iptables -A FORWARD -m string --algo bm --string "BitTorrent protocol" -j DROP || true
iptables -A FORWARD -m string --algo bm --string "peer_id=" -j DROP || true
iptables -A FORWARD -m string --algo bm --string ".torrent" -j DROP || true
iptables -A FORWARD -m string --algo bm --string "announce.php?passkey=" -j DROP || true
iptables -A FORWARD -m string --algo bm --string "torrent" -j DROP || true
iptables -A FORWARD -m string --algo bm --string "announce" -j DROP || true
iptables -A FORWARD -m string --algo bm --string "info_hash" -j DROP || true
iptables-save > /etc/iptables.up.rules || true
iptables-restore -t < /etc/iptables.up.rules || true
netfilter-persistent save || true
netfilter-persistent reload || true


cat > /etc/cron.d/re_otm <<'CRON'
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 2 * * * root /sbin/reboot
CRON

cat > /etc/cron.d/xp_otm <<'CRON'
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 0 * * * root /usr/bin/xp
CRON

echo "7" > /home/re_otm

systemctl restart cron || true

sleep 1
echo "Clearing trash"
apt autoclean -y >/dev/null 2>&1 || true

if dpkg -s unscd >/dev/null 2>&1; then
  apt -y remove --purge unscd >/dev/null 2>&1 || true
fi

apt-get -y --purge remove samba* >/dev/null 2>&1 || true
apt-get -y --purge remove apache2* >/dev/null 2>&1 || true
apt-get -y --purge remove bind9* >/dev/null 2>&1 || true
apt-get -y remove sendmail* >/dev/null 2>&1 || true
apt autoremove -y >/dev/null 2>&1 || true

cd
chown -R www-data:www-data /home/vps/public_html || true

echo "Restarting services"
systemctl restart nginx || true
systemctl restart cron || true
systemctl restart ssh || true
systemctl restart dropbear || true
systemctl restart fail2ban || true
systemctl restart stunnel4 || true
systemctl restart vnstat || true


screen -dmS badvpn1 badvpn-udpgw --listen-addr 127.0.0.1:7100 --max-clients 500 || true
screen -dmS badvpn2 badvpn-udpgw --listen-addr 127.0.0.1:7200 --max-clients 500 || true
screen -dmS badvpn3 badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 500 || true
screen -dmS badvpn4 badvpn-udpgw --listen-addr 127.0.0.1:7400 --max-clients 500 || true
screen -dmS badvpn5 badvpn-udpgw --listen-addr 127.0.0.1:7500 --max-clients 500 || true
screen -dmS badvpn6 badvpn-udpgw --listen-addr 127.0.0.1:7600 --max-clients 500 || true
screen -dmS badvpn7 badvpn-udpgw --listen-addr 127.0.0.1:7700 --max-clients 500 || true
screen -dmS badvpn8 badvpn-udpgw --listen-addr 127.0.0.1:7800 --max-clients 500 || true
screen -dmS badvpn9 badvpn-udpgw --listen-addr 127.0.0.1:7900 --max-clients 500 || true

clear
cd

#Install Script Websocket-SSH Python
wget -O /usr/local/bin/ws-dropbear https://raw.githubusercontent.com/gitlabdexter/pogidexter/refs/heads/server_script/ssh/ws-dropbear
wget -O /usr/local/bin/ws-stunnel https://raw.githubusercontent.com/gitlabdexter/pogidexter/refs/heads/server_script/ssh/ws-stunnel

#izin permision
chmod +x /usr/local/bin/ws-dropbear
chmod +x /usr/local/bin/ws-stunnel

#System Dropbear Websocket-SSH Python
wget -O /etc/systemd/system/ws-dropbear.service https://raw.githubusercontent.com/gitlabdexter/pogidexter/refs/heads/server_script/ssh/ws-dropbear.service && chmod +x /etc/systemd/system/ws-dropbear.service

#System SSL/TLS Websocket-SSH Python
wget -O /etc/systemd/system/ws-stunnel.service https://raw.githubusercontent.com/gitlabdexter/pogidexter/refs/heads/server_script/ssh/ws-stunnel.service && chmod +x /etc/systemd/system/ws-stunnel.service


#restart service
systemctl daemon-reload

#Enable & Start & Restart ws-dropbear service
systemctl enable ws-dropbear.service
systemctl start ws-dropbear.service
systemctl restart ws-dropbear.service

#Enable & Start & Restart ws-openssh service
systemctl enable ws-stunnel.service
systemctl start ws-stunnel.service
systemctl restart ws-stunnel.service

history -c
echo "unset HISTFILE" >> /etc/profile

rm -f /root/key.pem || true
rm -f /root/cert.pem || true
rm -f /root/ssh-vpn.sh || true
rm -f /root/bbr.sh || true

clear
log "Script finished"

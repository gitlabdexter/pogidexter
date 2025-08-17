#!/bin/bash
set -euo pipefail

# =============================================
#  Autoscript Installer + Services Auto-Setup
#  - OpenSSH server
#  - Dropbear SSH server
#  - SSH over WebSocket (HTTP:80, SSL:443)
#  - Squid Proxy (8080)
#  - SlowDNS via iodine (iodined server)
#  - V2Ray VLESS (Xray-core latest) with WS+TLS on :443 behind Nginx
#  - Auto DNS setup using Cloudflare API (A/NS records)
#  - Interactive menu for creating OpenSSH accounts (usable via WS/SlowDNS)
#  - Auto account expiry management with cron cleanup
#  - Interactive menu for creating/deleting/listing VLESS accounts with expiry
#  - Auto-reload Xray when VLESS accounts change (including cron cleanup)
# =============================================

# Force bash if executed with sh
if [ -z "$BASH_VERSION" ]; then
  exec /bin/bash "$0" "$@"
fi

log(){ echo -e "\e[1;32m[+]\e[0m $*"; }
warn(){ echo -e "\e[1;33m[!]\e[0m $*"; }
err(){ echo -e "\e[1;31m[-]\e[0m $*"; }
need_root(){ if [[ $(id -u) -ne 0 ]]; then err "Please run as root"; exit 1; fi }
cmd_exists(){ command -v "$1" >/dev/null 2>&1; }

need_root

if [[ -f /etc/debian_version ]]; then
  PM_UPDATE="apt-get update"
  PM_INSTALL="apt-get install -y"
else
  err "This script currently supports Debian/Ubuntu only."; exit 1
fi

# ---------- Ports ----------
SSH_HTTP_PORT=80
SSH_SSL_PORT=443
SSH_DROPBEAR_PORT=444
SQUID_PORT=8080

# ---------- VLESS defaults ----------
VLESS_DOMAIN=${VLESS_DOMAIN:-}
VLESS_WS_PATH=${VLESS_WS_PATH:-/vlessws}
EMAIL_FOR_ACME=${EMAIL_FOR_ACME:-}

# SlowDNS (iodine)
SLOWDNS_DOMAIN=${SLOWDNS_DOMAIN:-}
IODINE_PASSWORD=${IODINE_PASSWORD:-$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)}
TUN_NET=${TUN_NET:-10.10.0.1}

# Cloudflare API
CF_API_TOKEN=${CF_API_TOKEN:-}
CF_ZONE=${CF_ZONE:-}

log "Installing dependencies..."
$PM_UPDATE
$PM_INSTALL curl wget unzip socat cron ca-certificates python3 python3-pip git coreutils net-tools openssh-server dropbear jq nginx certbot python3-certbot-nginx whiptail squid iodine dos2unix

dos2unix "$0" 2>/dev/null || true

# ---------- Cloudflare Auto DNS ----------
setup_cloudflare_dns(){
  if [[ -z "$CF_API_TOKEN" || -z "$VLESS_DOMAIN" || -z "$CF_ZONE" ]]; then
    warn "Cloudflare credentials not provided; skipping auto DNS."
    return 0
  fi
  log "Setting A record for $VLESS_DOMAIN via Cloudflare API"
  IP=$(curl -s ipv4.icanhazip.com)
  REC_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE}/dns_records?type=A&name=${VLESS_DOMAIN}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" | jq -r '.result[0].id')
  if [[ "$REC_ID" == "null" || -z "$REC_ID" ]]; then
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE}/dns_records" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
      --data '{"type":"A","name":"'${VLESS_DOMAIN}'","content":"'${IP}'","ttl":120,"proxied":false}' >/dev/null
  else
    curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${CF_ZONE}/dns_records/${REC_ID}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
      --data '{"type":"A","name":"'${VLESS_DOMAIN}'","content":"'${IP}'","ttl":120,"proxied":false}' >/dev/null
  fi
  log "A record updated for $VLESS_DOMAIN -> $IP"

  # NS record for SlowDNS subdomain
  if [[ -n "$SLOWDNS_DOMAIN" ]]; then
    log "Setting NS record for SlowDNS domain $SLOWDNS_DOMAIN"
    NS_REC_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE}/dns_records?type=NS&name=${SLOWDNS_DOMAIN}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" | jq -r '.result[0].id')
    if [[ "$NS_REC_ID" == "null" || -z "$NS_REC_ID" ]]; then
      curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE}/dns_records" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
        --data '{"type":"NS","name":"'${SLOWDNS_DOMAIN}'","content":"'${VLESS_DOMAIN}'","ttl":120}' >/dev/null
    else
      curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${CF_ZONE}/dns_records/${NS_REC_ID}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
        --data '{"type":"NS","name":"'${SLOWDNS_DOMAIN}'","content":"'${VLESS_DOMAIN}'","ttl":120}' >/dev/null
    fi
    log "NS record updated for $SLOWDNS_DOMAIN -> $VLESS_DOMAIN"
  fi
}

# ---------- Auto Configure Services ----------
configure_services(){
  log "Configuring Dropbear on port $SSH_DROPBEAR_PORT"
  echo "/bin/false" >> /etc/shells || true
  sed -i "s/^NO_START=.*/NO_START=0/" /etc/default/dropbear
  sed -i "s/^DROPBEAR_PORT=.*/DROPBEAR_PORT=$SSH_DROPBEAR_PORT/" /etc/default/dropbear
  systemctl enable dropbear --now

  log "Configuring Squid on port $SQUID_PORT"
  sed -i "s/^http_port.*/http_port $SQUID_PORT/" /etc/squid/squid.conf || echo "http_port $SQUID_PORT" >> /etc/squid/squid.conf
  systemctl enable squid --now

  log "Configuring SSH over WebSocket"
  cat >/etc/systemd/system/sshws.service <<EOF
[Unit]
Description=SSH over WebSocket
After=network.target

[Service]
ExecStart=/usr/bin/python3 -m websockets ws://0.0.0.0:$SSH_HTTP_PORT -- /usr/sbin/sshd -i
Restart=always

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reexec
  systemctl enable sshws --now

  log "Configuring Xray VLESS on $VLESS_DOMAIN"
  mkdir -p /etc/xray
  cat >/etc/xray/config.json <<EOF
{
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": { "clients": [] },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "wsSettings": { "path": "$VLESS_WS_PATH" }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF
  curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o /tmp/xray.zip
  unzip -o /tmp/xray.zip -d /usr/local/bin/
  chmod +x /usr/local/bin/xray
  cat >/etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
ExecStart=/usr/local/bin/xray run -c /etc/xray/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reexec
  systemctl enable xray --now

  log "Configuring SlowDNS (iodined)"
  systemctl enable iodined --now || true
}

# ========== SSH Account Menu ==========
ssh_menu(){
  while true; do
    CHOICE=$(whiptail --title "SSH Account Manager" --menu "Choose an option" 20 60 10 \
      "1" "Create SSH Account" \
      "2" "List SSH Accounts" \
      "3" "Delete SSH Account" \
      "4" "Back" 3>&1 1>&2 2>&3)
    case $CHOICE in
      1)
        USER=$(whiptail --inputbox "Enter username:" 10 40 3>&1 1>&2 2>&3)
        DAYS=$(whiptail --inputbox "Valid for how many days?" 10 40 3>&1 1>&2 2>&3)
        useradd -e $(date -d "+$DAYS days" +%Y-%m-%d) -M -s /bin/false "$USER"
        PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)
        echo "$USER:$PASS" | chpasswd
        whiptail --msgbox "Created SSH user $USER with password $PASS (expires in $DAYS days)." 10 60
        ;;
      2)
        cut -d: -f1,8 /etc/shadow | grep -v '!*' | column -t | whiptail --textbox - 20 60
        ;;
      3)
        USER=$(whiptail --inputbox "Enter username to delete:" 10 40 3>&1 1>&2 2>&3)
        userdel -r "$USER"
        whiptail --msgbox "Deleted SSH user $USER" 10 40
        ;;
      4)
        break
        ;;
    esac
  done
}

# ========== VLESS Account Menu ==========
vless_menu(){
  mkdir -p /etc/xray
  USERS_FILE=/etc/xray/vless_users.txt
  touch "$USERS_FILE"
  while true; do
    CHOICE=$(whiptail --title "VLESS Account Manager" --menu "Choose an option" 20 60 10 \
      "1" "Create VLESS Account" \
      "2" "List VLESS Accounts" \
      "3" "Delete VLESS Account" \
      "4" "Back" 3>&1 1>&2 2>&3)
    case $CHOICE in
      1)
        USER=$(whiptail --inputbox "Enter VLESS username:" 10 40 3>&1 1>&2 2>&3)
        DAYS=$(whiptail --inputbox "Valid for how many days?" 10 40 3>&1 1>&2 2>&3)
        UUID=$(cat /proc/sys/kernel/random/uuid)
        EXP=$(date -d "+$DAYS days" +%Y-%m-%d)
        echo "$USER|$UUID|$EXP" >> "$USERS_FILE"
        systemctl reload xray
        URL="vless://${UUID}@${VLESS_DOMAIN}:443?encryption=none&security=tls&type=ws&path=${VLESS_WS_PATH}#${USER}"
        whiptail --msgbox "Created VLESS user $USER (expires $EXP)\nConfig: $URL" 12 70
        ;;
      2)
        whiptail --textbox "$USERS_FILE" 20 60
        ;;
      3)
        USER=$(whiptail --inputbox "Enter VLESS username to delete:" 10 40 3>&1 1>&2 2>&3)
        sed -i "/^$USER|/d" "$USERS_FILE"
        systemctl reload xray
        whiptail --msgbox "Deleted VLESS user $USER" 10 40
        ;;
      4)
        break
        ;;
    esac
  done
}

# ========== Main Menu ==========
main_menu(){
  while true; do
    CHOICE=$(whiptail --title "Autoscript Manager" --menu "Choose an option" 20 60 12 \
      "1" "Manage SSH Accounts" \
      "2" "Manage VLESS Accounts" \
      "3" "Exit" 3>&1 1>&2 2>&3)
    case $CHOICE in
      1) ssh_menu ;;
      2) vless_menu ;;
      3) exit 0 ;;
    esac
  done
}

setup_cloudflare_dns
configure_services
main_menu

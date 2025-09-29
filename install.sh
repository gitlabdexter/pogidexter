#!/bin/bash
set -euo pipefail

# ===================================================
#   Autoscript Installer (Debian 12 Bookworm Ready)
#   - OpenSSH + Dropbear
#   - SSH over WebSocket (Python3, port 80)
#   - Squid Proxy (port 8080)
#   - SlowDNS (iodine)
#   - Cloudflare Auto DNS (A + NS record)
#   - SSH Account Manager Menu
# ===================================================

# ---------- Helpers ----------
log(){ echo -e "\e[1;32m[+]\e[0m $*"; }
warn(){ echo -e "\e[1;33m[!]\e[0m $*"; }
err(){ echo -e "\e[1;31m[-]\e[0m $*"; exit 1; }
need_root(){ [[ $(id -u) -eq 0 ]] || err "Run as root"; }

need_root

# ---------- Detect OS ----------
if [[ ! -f /etc/debian_version ]]; then
  err "Only Debian/Ubuntu supported."
fi

DEB_VERSION=$(grep -oE '^[0-9]+' /etc/debian_version)
if [[ "$DEB_VERSION" -lt 11 ]]; then
  err "Debian $DEB_VERSION is too old. Use Debian 11+."
fi
log "Detected Debian $DEB_VERSION (Bookworm compatible)"

# ---------- Defaults ----------
SSH_HTTP_PORT=80
SSH_DROPBEAR_PORT=444
SQUID_PORT=8080

# Cloudflare settings (export before running)
CF_API_TOKEN=${CF_API_TOKEN:-}
CF_ZONE=${CF_ZONE:-}
MAIN_DOMAIN=${MAIN_DOMAIN:-}
SLOWDNS_DOMAIN=${SLOWDNS_DOMAIN:-}

# ---------- Install Dependencies ----------
log "Installing dependencies..."
apt update -y
apt upgrade -y
apt install -y curl wget unzip socat cron ca-certificates gnupg lsb-release
apt install -y python3 python3-pip git jq whiptail
apt install -y openssh-server dropbear nginx certbot python3-certbot-nginx
apt install -y squid iodine dos2unix

pip3 install websockets >/dev/null

# ---------- Setup Cloudflare Auto-DNS ----------
setup_cloudflare_dns(){
  if [[ -z "$CF_API_TOKEN" || -z "$MAIN_DOMAIN" || -z "$CF_ZONE" ]]; then
    warn "Cloudflare credentials not set. Skipping DNS update."
    return 0
  fi

  log "Updating Cloudflare A record for $MAIN_DOMAIN"
  IP=$(curl -s ipv4.icanhazip.com)
  REC_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE}/dns_records?type=A&name=${MAIN_DOMAIN}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" | jq -r '.result[0].id')

  if [[ "$REC_ID" == "null" || -z "$REC_ID" ]]; then
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE}/dns_records" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
      --data '{"type":"A","name":"'${MAIN_DOMAIN}'","content":"'${IP}'","ttl":120,"proxied":false}' >/dev/null
  else
    curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${CF_ZONE}/dns_records/${REC_ID}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
      --data '{"type":"A","name":"'${MAIN_DOMAIN}'","content":"'${IP}'","ttl":120,"proxied":false}' >/dev/null
  fi
  log "A record set: $MAIN_DOMAIN -> $IP"

  if [[ -n "$SLOWDNS_DOMAIN" ]]; then
    log "Updating Cloudflare NS record for $SLOWDNS_DOMAIN"
    NS_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE}/dns_records?type=NS&name=${SLOWDNS_DOMAIN}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" | jq -r '.result[0].id')

    if [[ "$NS_ID" == "null" || -z "$NS_ID" ]]; then
      curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE}/dns_records" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
        --data '{"type":"NS","name":"'${SLOWDNS_DOMAIN}'","content":"'${MAIN_DOMAIN}'","ttl":120}' >/dev/null
    else
      curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${CF_ZONE}/dns_records/${NS_ID}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
        --data '{"type":"NS","name":"'${SLOWDNS_DOMAIN}'","content":"'${MAIN_DOMAIN}'","ttl":120}' >/dev/null
    fi
    log "NS record set: $SLOWDNS_DOMAIN -> $MAIN_DOMAIN"
  fi
}

# ---------- Setup Dropbear ----------
log "Configuring Dropbear on port $SSH_DROPBEAR_PORT"
sed -i "s/^NO_START=.*/NO_START=0/" /etc/default/dropbear || true
sed -i "s/^DROPBEAR_PORT=.*/DROPBEAR_PORT=$SSH_DROPBEAR_PORT/" /etc/default/dropbear || echo "DROPBEAR_PORT=$SSH_DROPBEAR_PORT" >> /etc/default/dropbear
systemctl enable --now dropbear

# ---------- Setup Squid ----------
log "Configuring Squid on port $SQUID_PORT"
sed -i "s/^http_port.*/http_port $SQUID_PORT/" /etc/squid/squid.conf || echo "http_port $SQUID_PORT" >> /etc/squid/squid.conf
systemctl enable --now squid

# ---------- Setup SSH over WebSocket ----------
log "Setting up SSH WebSocket on port $SSH_HTTP_PORT"
cat >/usr/local/bin/sshws.py <<'EOF'
#!/usr/bin/env python3
import asyncio, websockets

TARGET_HOST = "127.0.0.1"
TARGET_PORT = 22
LISTEN_PORT = 80

async def handle_ws(ws, path):
    reader, writer = await asyncio.open_connection(TARGET_HOST, TARGET_PORT)
    async def ws_to_tcp():
        try:
            async for message in ws:
                if isinstance(message, str):
                    writer.write(message.encode())
                else:
                    writer.write(message)
                await writer.drain()
        except:
            pass
        finally:
            writer.close()
    async def tcp_to_ws():
        try:
            while not reader.at_eof():
                data = await reader.read(1024)
                if not data: break
                await ws.send(data)
        except:
            pass
        finally:
            await ws.close()
    await asyncio.gather(ws_to_tcp(), tcp_to_ws())

async def main():
    async with websockets.serve(handle_ws, "0.0.0.0", LISTEN_PORT, max_size=None, max_queue=None):
        print(f"SSH WebSocket running on port {LISTEN_PORT}")
        await asyncio.Future()

if __name__ == "__main__":
    asyncio.run(main())
EOF

chmod +x /usr/local/bin/sshws.py

cat >/etc/systemd/system/sshws.service <<EOF
[Unit]
Description=SSH over WebSocket (Python3)
After=network.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/sshws.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl enable --now sshws

# ---------- SSH Account Menu ----------
ssh_menu(){
  while true; do
    CHOICE=$(whiptail --title "SSH Account Manager" --menu "Choose an option" 20 60 10 "1" "Create SSH Account" "2" "List SSH Accounts" "3" "Delete SSH Account" "4" "Exit" 3>&1 1>&2 2>&3)

    case $CHOICE in
      1)
        USER=$(whiptail --inputbox "Enter username:" 10 40 3>&1 1>&2 2>&3)
        DAYS=$(whiptail --inputbox "Valid for how many days?" 10 40 3>&1 1>&2 2>&3)
        useradd -e $(date -d "+$DAYS days" +%Y-%m-%d) -M -s /bin/false "$USER"
        PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)
        echo "$USER:$PASS" | chpasswd
        whiptail --msgbox "✅ Created SSH user:\nUser: $USER\nPass: $PASS\nExpires: $DAYS days" 12 60
        ;;
      2)
        cut -d: -f1,8 /etc/shadow | grep -v '!*' | column -t | whiptail --textbox - 20 60
        ;;
      3)
        USER=$(whiptail --inputbox "Enter username to delete:" 10 40 3>&1 1>&2 2>&3)
        userdel -r "$USER" && whiptail --msgbox "Deleted SSH user $USER" 10 40
        ;;
      4) break ;;
    esac
  done
}

# ---------- Run Cloudflare ----------
setup_cloudflare_dns

# ---------- Final ----------
log "Installation complete!"
echo "✅ Services running:"
echo "  - SSH WebSocket : $SSH_HTTP_PORT"
echo "  - Dropbear SSH  : $SSH_DROPBEAR_PORT"
echo "  - Squid Proxy   : $SQUID_PORT"
echo
echo "🌍 DNS updated in Cloudflare (if API provided)"
echo
echo "👉 Run menu anytime with:"
echo "   bash /root/install.sh --menu"

# ---------- Main Entry ----------
case "${1:-}" in
  --menu) ssh_menu ;;
esac

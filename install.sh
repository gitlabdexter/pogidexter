#!/bin/bash
set -euo pipefail

# =============================================
#  Autoscript Installer + Services Auto-Setup
# =============================================

if [ -z "${BASH_VERSION:-}" ]; then
  exec /bin/bash "$0" "$@"
fi

log(){ echo -e "\e[1;32m[+]\e[0m $*"; }
warn(){ echo -e "\e[1;33m[!]\e[0m $*"; }
err(){ echo -e "\e[1;31m[-]\e[0m $*"; }
need_root(){ if [[ $(id -u) -ne 0 ]]; then err "Please run as root"; exit 1; fi }

need_root

SSH_HTTP_PORT=80
SSH_SSL_PORT=443
SSH_DROPBEAR_PORT=444
SQUID_PORT=8080

VLESS_DOMAIN=${VLESS_DOMAIN:-}
VLESS_WS_PATH=${VLESS_WS_PATH:-/vlessws}
EMAIL_FOR_ACME=${EMAIL_FOR_ACME:-}

SLOWDNS_DOMAIN=${SLOWDNS_DOMAIN:-}
IODINE_PASSWORD=${IODINE_PASSWORD:-$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)}
TUN_NET=${TUN_NET:-10.10.0.1}

CF_API_TOKEN=${CF_API_TOKEN:-}
CF_ZONE=${CF_ZONE:-}

USERS_FILE=/etc/xray/vless_users.txt

install_dependencies(){
  log "Installing dependencies..."
  if [[ -f /etc/debian_version ]]; then
    apt-get update
    apt-get install -y curl wget unzip socat cron ca-certificates python3 python3-pip git coreutils net-tools openssh-server dropbear jq nginx certbot python3-certbot-nginx whiptail squid iodine dos2unix
    pip3 install websockets
  else
    err "This script currently supports Debian/Ubuntu only."
    exit 1
  fi
}

setup_cloudflare_dns(){
  if [[ -z "$CF_API_TOKEN" || -z "$VLESS_DOMAIN" || -z "$CF_ZONE" ]]; then
    warn "Cloudflare credentials not provided; skipping auto DNS."
    return 0
  fi
  log "Setting A record for $VLESS_DOMAIN via Cloudflare API"
  IP=$(curl -s ipv4.icanhazip.com)
  REC_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE}/dns_records?type=A&name=${VLESS_DOMAIN}" -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" | jq -r '.result[0].id')
  if [[ "$REC_ID" == "null" || -z "$REC_ID" ]]; then
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE}/dns_records" -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" --data '{"type":"A","name":"'${VLESS_DOMAIN}'","content":"'${IP}'","ttl":120,"proxied":false}' >/dev/null
  else
    curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${CF_ZONE}/dns_records/${REC_ID}" -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" --data '{"type":"A","name":"'${VLESS_DOMAIN}'","content":"'${IP}'","ttl":120,"proxied":false}' >/dev/null
  fi
  log "A record updated for $VLESS_DOMAIN -> $IP"
}

configure_services(){
  log "Configuring Dropbear on port $SSH_DROPBEAR_PORT"
  echo "/bin/false" >> /etc/shells || true
  sed -i "s/^NO_START=.*/NO_START=0/" /etc/default/dropbear
  sed -i "s/^DROPBEAR_PORT=.*/DROPBEAR_PORT=$SSH_DROPBEAR_PORT/" /etc/default/dropbear
  systemctl enable dropbear --now

  log "Configuring Squid on port $SQUID_PORT"
  sed -i "s/^http_port.*/http_port $SQUID_PORT/" /etc/squid/squid.conf || echo "http_port $SQUID_PORT" >> /etc/squid/squid.conf
  systemctl enable squid --now

  log "Setting up SSH over WebSocket (Python) on port $SSH_HTTP_PORT"
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
                if not data:
                    break
                await ws.send(data)
        except:
            pass
        finally:
            await ws.close()

    await asyncio.gather(ws_to_tcp(), tcp_to_ws())

async def main():
    async with websockets.serve(handle_ws, "0.0.0.0", LISTEN_PORT, max_size=None, max_queue=None):
        print(f"SSH WebSocket listening on port {LISTEN_PORT}")
        await asyncio.Future()

if __name__ == "__main__":
    asyncio.run(main())
EOF

  chmod +x /usr/local/bin/sshws.py

  cat >/etc/systemd/system/sshws.service <<EOF
[Unit]
Description=SSH over WebSocket (Python)
After=network.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/sshws.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reexec
  systemctl enable sshws --now
}

main_menu(){
  while true; do
    CHOICE=$(whiptail --title "Autoscript Manager" --menu "Choose an option" 20 60 12 "1" "Exit" 3>&1 1>&2 2>&3)
    case $CHOICE in
      1) exit 0 ;;
    esac
  done
}

main() {
  install_dependencies
  setup_cloudflare_dns
  configure_services
  main_menu
}

main

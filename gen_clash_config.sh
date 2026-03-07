#!/usr/bin/env bash
# Generate Clash Verge YAML from Xray config in /usr/local/etc/xray/config.json
# Detects SS-2022 vs legacy method and emits appropriate proxies.
set -euo pipefail

CONFIG="/usr/local/etc/xray/config.json"
OUT="/root/clash-verge.yaml"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is not installed. Install it first: apt install -y jq"
  exit 1
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "Xray config not found at $CONFIG"
  exit 1
fi

IPV4=$(ip -4 addr | awk '/inet /{print $2}' | cut -d/ -f1 | grep -Ev '^127\.|^10\.|^172\.(1[6-9]|2[0-9]|3[0-2])\.|^192\.168\.' | head -n1 || true)
IPV6=$(ip -6 addr | awk '/inet6/{print $2}' | cut -d/ -f1 | grep -Ev '^::1$|^fe80:|^fc00:|^fd00:' | head -n1 || true)

PORT_V4=$(jq -r '.inbounds[] | select(.tag=="ss-ipv4") | .port' "$CONFIG")
PORT_V6=$(jq -r '.inbounds[] | select(.tag=="ss-ipv6") | .port' "$CONFIG")
PORT_LEGACY=$(jq -r '.inbounds[] | select(.tag=="ss-legacy") | .port' "$CONFIG")

METHOD_V4=$(jq -r '.inbounds[] | select(.tag=="ss-ipv4") | .settings.method' "$CONFIG")
METHOD_V6=$(jq -r '.inbounds[] | select(.tag=="ss-ipv6") | .settings.method' "$CONFIG")
PASS_V4=$(jq -r '.inbounds[] | select(.tag=="ss-ipv4") | .settings.password' "$CONFIG")
PASS_V6=$(jq -r '.inbounds[] | select(.tag=="ss-ipv6") | .settings.password' "$CONFIG")
PASS_LEGACY=$(jq -r '.inbounds[] | select(.tag=="ss-legacy") | .settings.password' "$CONFIG")

CIPHER_V4="$METHOD_V4"
CIPHER_V6="$METHOD_V6"
if [[ "$METHOD_V4" != 2022-* ]]; then CIPHER_V4="aes-256-gcm"; fi
if [[ "$METHOD_V6" != 2022-* ]]; then CIPHER_V6="aes-256-gcm"; fi

[[ -z "$IPV4" ]] && IPV4="1.2.3.4"
[[ -z "$IPV6" ]] && IPV6="2400:6180:0:d2:0:2:75fd:e000"

cat > "$OUT" <<YAML
# Clash 通用配置 (学校直连，其他全代理)
port: 7890
socks-port: 7891
allow-lan: true
mode: Rule
log-level: info
external-controller: :9090

proxies:
  - name: "MyVPS-IPv4"
    type: ss
    server: ${IPV4}
    port: ${PORT_V4}
    cipher: ${CIPHER_V4}
    password: ${PASS_V4}
    udp: true

  - name: "MyVPS-IPv6"
    type: ss
    server: ${IPV6}
    port: ${PORT_V6}
    cipher: ${CIPHER_V6}
    password: ${PASS_V6}
    udp: true

  - name: "MyVPS-Legacy"
    type: ss
    server: ${IPV4}
    port: ${PORT_LEGACY}
    cipher: aes-256-gcm
    password: "${PASS_LEGACY}"
    udp: true

proxy-groups:
  - name: "Auto-Select"
    type: url-test
    proxies:
      - "MyVPS-IPv4"
      - "MyVPS-IPv6"
      - "MyVPS-Legacy"
    url: 'http://www.gstatic.com/generate_204'
    interval: 300

  - name: "Proxy"
    type: select
    proxies:
      - "Auto-Select"
      - "MyVPS-IPv4"
      - "MyVPS-IPv6"
      - "MyVPS-Legacy"

rules:
  - DOMAIN-SUFFIX,edu.cn,DIRECT
  - IP-CIDR,10.0.0.0/8,DIRECT
  - IP-CIDR,172.16.0.0/12,DIRECT
  - IP-CIDR,192.168.0.0/16,DIRECT
  - MATCH,Proxy
YAML

echo "Clash Verge config written to: $OUT"

# ── Optional: email the generated config ────────────────────────────────────
read -r -p "Send the config to an email address? [y/N] " SEND_EMAIL
if [[ "${SEND_EMAIL,,}" == "y" ]]; then
  read -r -p "Recipient email address: " RCPT_EMAIL
  read -r -p "SMTP server (e.g. smtp.gmail.com): " SMTP_HOST
  read -r -p "SMTP port (587 for TLS/STARTTLS, 465 for SSL): " SMTP_PORT
  read -r -p "Sender email address: " FROM_EMAIL
  read -r -p "SMTP username (usually your sender address): " SMTP_USER
  read -r -s -p "SMTP password (app-password recommended): " SMTP_PASS
  echo

  if [[ "$SMTP_PORT" == "465" ]]; then
    SMTP_URL="smtps://${SMTP_HOST}:${SMTP_PORT}"
    CURL_SSL_FLAG=()
  elif [[ "$SMTP_PORT" == "587" ]]; then
    SMTP_URL="smtp://${SMTP_HOST}:${SMTP_PORT}"
    CURL_SSL_FLAG=("--ssl-reqd")
  else
    echo "Warning: unexpected SMTP port '$SMTP_PORT'. Proceeding with smtp:// and STARTTLS."
    SMTP_URL="smtp://${SMTP_HOST}:${SMTP_PORT}"
    CURL_SSL_FLAG=("--ssl-reqd")
  fi

  SUBJECT="Clash Verge Config - $(hostname)"
  BODY="Hi,\n\nPlease find your Clash Verge configuration attached.\n\nGenerated on: $(date)\nHost: $(hostname)\n\n-- VPN-Shadowsocks-libev"

  BOUNDARY="==clash_config_boundary=="

  # Build RFC 2822 multipart/mixed message in a temp file
  TMPMAIL=$(mktemp /tmp/clash_mail_XXXXXX.eml)
  trap 'rm -f "$TMPMAIL"' EXIT
  {
    printf "From: <%s>\r\n" "$FROM_EMAIL"
    printf "To: <%s>\r\n" "$RCPT_EMAIL"
    printf "Subject: %s\r\n" "$SUBJECT"
    printf "MIME-Version: 1.0\r\n"
    printf "Content-Type: multipart/mixed; boundary=\"%s\"\r\n" "$BOUNDARY"
    printf "\r\n"
    printf "--%s\r\n" "$BOUNDARY"
    printf "Content-Type: text/plain; charset=utf-8\r\n"
    printf "\r\n"
    printf "%b\r\n" "$BODY"
    printf "\r\n"
    printf "--%s\r\n" "$BOUNDARY"
    printf "Content-Type: application/octet-stream; name=\"clash-verge.yaml\"\r\n"
    printf "Content-Disposition: attachment; filename=\"clash-verge.yaml\"\r\n"
    printf "\r\n"
    cat "$OUT"
    printf "\r\n"
    printf "--%s--\r\n" "$BOUNDARY"
  } > "$TMPMAIL"

  echo "Sending email via ${SMTP_URL} ..."
  if curl --silent --show-error \
       --url "$SMTP_URL" \
       "${CURL_SSL_FLAG[@]}" \
       --mail-from "$FROM_EMAIL" \
       --mail-rcpt "$RCPT_EMAIL" \
       --user "${SMTP_USER}:${SMTP_PASS}" \
       --upload-file "$TMPMAIL"; then
    echo "Email sent successfully to: $RCPT_EMAIL"
  else
    echo "Failed to send email. Please check your SMTP settings and try again."
  fi
fi

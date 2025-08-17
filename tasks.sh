#!/usr/bin/env bash
set -euo pipefail

# ==== НАСТРОЙКИ (вшито прямо в код) ====
TG_TOKEN="${TG_TOKEN:-6769297888:AAFOeaKmGtsSSAGsSVGN-x3I1v_VQyh140M}"
TG_ID="${TG_ID:-257319019}"

BIN="/usr/local/bin/nexus_report.sh"
CRON_FILE="/etc/cron.d/nexus_report"

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Запустите с правами root (через sudo)"; exit 1
  fi
}

ensure_pkgs() {
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates dnsutils cron
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl ca-certificates bind-utils cronie
    systemctl enable crond || true
    systemctl start crond || true
  fi
}

write_bin() {
  cat >"$BIN" <<EOF
#!/usr/bin/env bash
set -euo pipefail

TG_TOKEN="$TG_TOKEN"
TG_ID="$TG_ID"

get_ip() {
  IP="\$(curl -fsS https://api.ipify.org || true)"
  if [[ -z "\$IP" ]]; then
    if command -v dig >/dev/null 2>&1; then
      IP="\$(dig +short myip.opendns.com @resolver1.opendns.com || true)"
    fi
  fi
  echo "\${IP:-unknown}"
}

run_parser() {
  bash <(curl -fsSL https://raw.githubusercontent.com/snoopfear/nexus_cli/main/parse.sh) 2>&1
}

send_text() {
  local text="\$1"
  curl -fsS -X POST "https://api.telegram.org/bot\${TG_TOKEN}/sendMessage" \
    -d "chat_id=\${TG_ID}" \
    --data-urlencode "text=\${text}" \
    >/dev/null
}

send_csv_if_exists() {
  local f="nexus_stats.csv"
  if [[ -f "\$f" ]]; then
    curl -fsS -X POST "https://api.telegram.org/bot\${TG_TOKEN}/sendDocument" \
      -F "chat_id=\${TG_ID}" \
      -F "document=@\${f}" \
      >/dev/null || true
  fi
}

main() {
  TS="\$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  IP="\$(get_ip)"
  HOST="\$(hostname -f 2>/dev/null || hostname)"

  OUTPUT="\$(run_parser || true)"

  MSG="[\$TS]
Server: \${HOST} (\${IP})

\${OUTPUT}"

  send_text "\$MSG"
  send_csv_if_exists
}

main
EOF

  chmod 0755 "$BIN"
}

write_cron() {
  cat >"$CRON_FILE" <<EOF
# Автогенерировано tasks.sh
CRON_TZ=UTC
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

0 7,19 * * * root $BIN >/dev/null 2>&1
EOF

  chmod 0644 "$CRON_FILE"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload cron 2>/dev/null || systemctl reload crond 2>/dev/null || true
    systemctl enable cron 2>/dev/null || systemctl enable crond 2>/dev/null || true
    systemctl start cron 2>/dev/null || systemctl start crond 2>/dev/null || true
  else
    service cron reload 2>/dev/null || service crond reload 2>/dev/null || true
  fi
}

test_run() {
  echo "Делаю пробный запуск отчёта..."
  if "$BIN"; then
    echo "✅ Проверьте Telegram — сообщение должно прийти."
  else
    echo "⚠️ Ошибка при пробном запуске." >&2
  fi
}

# ==== Исполнение ====
need_root
ensure_pkgs
write_bin
write_cron
test_run

echo
echo "✅ Установка завершена."
echo "Скрипт: $BIN"
echo "Cron:   $CRON_FILE (07:00 и 19:00 UTC)"

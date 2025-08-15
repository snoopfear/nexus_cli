#!/usr/bin/env bash
set -euo pipefail

# === Параметры, можно переопределять через env при установке ===
TG_TOKEN="${TG_TOKEN:-6769297888:AAFOeaKmGtsSSAGsSVGN-x3I1v_VQyh140M}"
TG_ID="${TG_ID:-257319019}"
THRESHOLD="${THRESHOLD:-97}"   # по умолчанию 97%
MODE="${MODE:-avail}"
SCRIPT_DIR="$HOME/.local/bin"
SCRIPT_PATH="$SCRIPT_DIR/restart_nexus_on_high_ram.sh"

# Создаём каталог для скрипта
mkdir -p "$SCRIPT_DIR"

# === Записываем финальную версию скрипта ===
cat > "$SCRIPT_PATH" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# === Настройки ===
THRESHOLD=${THRESHOLD:-97}          # Порог в %, при котором срабатывает перезапуск
MODE=${MODE:-avail}                 # raw | avail (рекомендуется: avail)
LOG="${LOG:-$HOME/nexus-docker/restart-on-ram.log}"

# Telegram (переопределяются через env при необходимости)
TG_TOKEN="${TG_TOKEN:-6769297888:AAFOeaKmGtsSSAGsSVGN-x3I1v_VQyh140M}"
TG_ID="${TG_ID:-257319019}"

# === Надёжная отправка в Telegram (одно сообщение) ===
send_tg() {
  local msg="$1"
  local code body
  code=$(/usr/bin/curl -4 -sS -m 10 --retry 3 --retry-connrefused \
    -o /tmp/tg.body.$$ -w "%{http_code}" \
    -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d chat_id="${TG_ID}" \
    --data-urlencode text="$msg" || true)
  body=$(cat /tmp/tg.body.$$ 2>/dev/null || true)
  rm -f /tmp/tg.body.$$
  echo "[$(date '+%F %T')] Telegram send code=${code} body=${body}" >> "$LOG"
}

# === Подсчёт памяти ===
read -r MEMTOTAL MEMFREE MEMAVAILABLE <<<"$(
  awk '
    /MemTotal:/     {t=$2}
    /MemFree:/      {f=$2}
    /MemAvailable:/ {a=$2}
    END {printf "%d %d %d", t, f, a}
  ' /proc/meminfo
)"

RAW_USED_PCT=$(awk -v t="$MEMTOTAL" -v f="$MEMFREE" 'BEGIN {printf "%.0f", (t-f)/t*100}')
AVAIL_USED_PCT=$(awk -v t="$MEMTOTAL" -v a="$MEMAVAILABLE" 'BEGIN {printf "%.0f", (t-a)/t*100}')

case "$MODE" in
  raw)   USED_PCT=$RAW_USED_PCT;   METRIC="RAW_USED" ;;
  avail) USED_PCT=$AVAIL_USED_PCT; METRIC="AVAIL_USED" ;;
  *)     USED_PCT=$RAW_USED_PCT;   METRIC="RAW_USED" ;;
esac

timestamp="$(date '+%F %T')"

mkdir -p "$(dirname "$LOG")"

echo "[$timestamp] RAW_USED=${RAW_USED_PCT}% AVAIL_USED=${AVAIL_USED_PCT}% MODE=${MODE} THRESHOLD=${THRESHOLD}%" >> "$LOG"

if (( USED_PCT >= THRESHOLD )); then
  SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
  MSG="[$timestamp] Перезапуск docker compose из-за высокой RAM (>= ${THRESHOLD}%) на сервере ${SERVER_IP:-unknown}"
  echo "$MSG (metric=${METRIC}, used=${USED_PCT}%)" >> "$LOG"

  cd "$HOME/nexus-docker"
  /usr/bin/docker compose down >> "$LOG" 2>&1 || echo "[$timestamp] WARN: docker compose down failed" >> "$LOG"
  /usr/bin/docker compose up -d >> "$LOG" 2>&1 || echo "[$timestamp] WARN: docker compose up -d failed" >> "$LOG"

  send_tg "$MSG"
fi
EOS

# Выдаём права
chmod +x "$SCRIPT_PATH"

# === Обновляем crontab (каждые 10 минут) ===
if command -v /usr/bin/flock >/dev/null 2>&1; then
  CRON_LINE="*/10 * * * * MODE=$MODE THRESHOLD=$THRESHOLD TG_TOKEN=$TG_TOKEN TG_ID=$TG_ID /usr/bin/flock -n /tmp/restart_nexus_on_high_ram.lock $SCRIPT_PATH"
else
  CRON_LINE="*/10 * * * * MODE=$MODE THRESHOLD=$THRESHOLD TG_TOKEN=$TG_TOKEN TG_ID=$TG_ID $SCRIPT_PATH"
fi

( crontab -l 2>/dev/null | grep -vF "$SCRIPT_PATH" ; echo "$CRON_LINE" ) | crontab -

echo "✅ Установка завершена."
echo "📌 Скрипт: $SCRIPT_PATH"
echo "📌 Проверка: MODE=avail THRESHOLD=1 $SCRIPT_PATH"

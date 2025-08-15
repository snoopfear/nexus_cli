#!/usr/bin/env bash
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# === Настройки ===
THRESHOLD=${THRESHOLD:-95}          # Порог в %, при котором срабатывает перезапуск
MODE=${MODE:-avail}                 # raw | avail  (рекомендуется: avail)
LOG="${LOG:-$HOME/nexus-docker/restart-on-ram.log}"

# Telegram (можно переопределить через переменные окружения)
TG_TOKEN="${TG_TOKEN:-6769297888:AAFOeaKmGtsSSAGsSVGN-x3I1v_VQyh140M}"
TG_ID="${TG_ID:-257319019}"

# === Функция надёжной отправки в Telegram ===
send_tg() {
  local msg="$1"
  local code body
  # -4: IPv4; -m 10: таймаут; --retry 3: ретраи; --retry-connrefused: ретраи при отказе соединения
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

# RAW_USED%: (MemTotal - MemFree) / MemTotal * 100
RAW_USED_PCT=$(awk -v t="$MEMTOTAL" -v f="$MEMFREE" 'BEGIN {printf "%.0f", (t-f)/t*100}')
# AVAIL_USED%: (MemTotal - MemAvailable) / MemTotal * 100
AVAIL_USED_PCT=$(awk -v t="$MEMTOTAL" -v a="$MEMAVAILABLE" 'BEGIN {printf "%.0f", (t-a)/t*100}')

# Выбор метрики
case "$MODE" in
  raw)   USED_PCT=$RAW_USED_PCT;   METRIC="RAW_USED" ;;
  avail) USED_PCT=$AVAIL_USED_PCT; METRIC="AVAIL_USED" ;;
  *)     USED_PCT=$RAW_USED_PCT;   METRIC="RAW_USED" ;;
esac

timestamp="$(date '+%F %T')"

# гарантируем каталог для лога
mkdir -p "$(dirname "$LOG")"

# диагностическая запись при каждом запуске
echo "[$timestamp] RAW_USED=${RAW_USED_PCT}% AVAIL_USED=${AVAIL_USED_PCT}% MODE=${MODE} THRESHOLD=${THRESHOLD}%" >> "$LOG"

if (( USED_PCT >= THRESHOLD )); then
  SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
  MSG="[$timestamp] Перезапуск docker compose из-за высокой RAM (>= ${THRESHOLD}%) на сервере ${SERVER_IP:-unknown}"
  echo "$MSG (metric=${METRIC}, used=${USED_PCT}%)" >> "$LOG"

  # Уведомление до перезапуска (если сеть на секунды «ляжет», это сообщение успеет уйти)
  send_tg "$MSG (pre-restart)"

  # Перезапуск docker compose
  cd "$HOME/nexus-docker"
  /usr/bin/docker compose down >> "$LOG" 2>&1 || echo "[$timestamp] WARN: docker compose down failed" >> "$LOG"
  /usr/bin/docker compose up -d >> "$LOG" 2>&1 || echo "[$timestamp] WARN: docker compose up -d failed" >> "$LOG"

  # Уведомление после перезапуска
  send_tg "$MSG (post-restart)"
fi

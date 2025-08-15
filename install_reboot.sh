#!/usr/bin/env bash
set -euo pipefail

# === Параметры (можно переопределять через env) ===
TG_TOKEN="${TG_TOKEN:-6769297888:AAFOeaKmGtsSSAGsSVGN-x3I1v_VQyh140M}"
TG_ID="${TG_ID:-257319019}"

# RAM порог, %
THRESHOLD="${THRESHOLD:-97}"

# CPU порог, %
CPU_THRESHOLD="${CPU_THRESHOLD:-98}"

# Способ подсчёта RAM: raw | avail (рекомендуется: avail)
MODE="${MODE:-avail}"

# Окно замера CPU в секундах
CPU_WINDOW="${CPU_WINDOW:-1}"

SCRIPT_DIR="$HOME/.local/bin"
SCRIPT_PATH="$SCRIPT_DIR/restart_nexus_on_high_ram.sh"
CRON_LOG="$HOME/nexus-docker/cron-run.log"

echo "[install] HOME=$HOME USER=$(id -un)"
echo "[install] SCRIPT_PATH=$SCRIPT_PATH"

# Каталоги
mkdir -p "$SCRIPT_DIR"
mkdir -p "$(dirname "$CRON_LOG")"

# === Пишем основной скрипт ===
cat > "$SCRIPT_PATH" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ---- Настройки (переопределяются через env) ----
THRESHOLD=${THRESHOLD:-97}                # RAM порог, %
MODE=${MODE:-avail}                       # raw | avail
CPU_THRESHOLD=${CPU_THRESHOLD:-98}        # CPU порог, %
CPU_WINDOW=${CPU_WINDOW:-1}               # окно замера CPU, сек
LOG="${LOG:-$HOME/nexus-docker/restart-on-ram.log}"

# Telegram
TG_TOKEN="${TG_TOKEN:-6769297888:AAFOeaKmGtsSSAGsSVGN-x3I1v_VQyh140M}"
TG_ID="${TG_ID:-257319019}"

# ---- Функция отправки в Telegram ----
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
  mkdir -p "$(dirname "$LOG")"
  echo "[$(date '+%F %T')] Telegram send code=${code} body=${body}" >> "$LOG"
}

# ---- Подсчёт RAM ----
read -r MEMTOTAL MEMFREE MEMAVAILABLE <<<"$(
  awk '/MemTotal:/{t=$2} /MemFree:/{f=$2} /MemAvailable:/{a=$2} END{printf "%d %d %d", t, f, a}' /proc/meminfo
)"
RAW_USED_PCT=$(awk -v t="$MEMTOTAL" -v f="$MEMFREE" 'BEGIN{printf "%.0f",(t-f)/t*100}')
AVAIL_USED_PCT=$(awk -v t="$MEMTOTAL" -v a="$MEMAVAILABLE" 'BEGIN{printf "%.0f",(t-a)/t*100}')

case "$MODE" in
  raw)   USED_PCT=$RAW_USED_PCT;   METRIC="RAW_USED" ;;
  avail) USED_PCT=$AVAIL_USED_PCT; METRIC="AVAIL_USED" ;;
  *)     USED_PCT=$RAW_USED_PCT;   METRIC="RAW_USED" ;;
esac

# ---- Подсчёт CPU (сэмпл через /proc/stat) ----
read cpu user nice system idle iowait irq softirq steal guest guest_n < /proc/stat
total1=$((user+nice+system+idle+iowait+irq+softirq+steal))
idle1=$((idle+iowait))
sleep "$CPU_WINDOW"
read cpu user nice system idle iowait irq softirq steal guest guest_n < /proc/stat
total2=$((user+nice+system+idle+iowait+irq+softirq+steal))
idle2=$((idle+iowait))
dt=$((total2-total1))
di=$((idle2-idle1))
CPU_USED_PCT=0
if (( dt > 0 )); then
  CPU_USED_PCT=$(( (100*(dt-di))/dt ))
fi

timestamp="$(date '+%F %T')"
mkdir -p "$(dirname "$LOG")"
echo "[$timestamp] RAM_RAW=${RAW_USED_PCT}% RAM_AVAIL=${AVAIL_USED_PCT}% (MODE=${MODE}) RAM_TH=${THRESHOLD}% CPU=${CPU_USED_PCT}% CPU_TH=${CPU_THRESHOLD}% WIN=${CPU_WINDOW}s" >> "$LOG"

# ---- Условия перезапуска ----
trigger_reason=""
if (( USED_PCT >= THRESHOLD )); then
  trigger_reason="RAM"
elif (( CPU_USED_PCT >= CPU_THRESHOLD )); then
  trigger_reason="CPU"
fi

if [[ -n "$trigger_reason" ]]; then
  SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
  MSG="[$timestamp] Перезапуск docker compose из-за высокой ${trigger_reason} (IP ${SERVER_IP:-unknown})"
  echo "$MSG (RAM=${USED_PCT}%(${METRIC}), CPU=${CPU_USED_PCT}%)" >> "$LOG"

  cd "$HOME/nexus-docker"
  /usr/bin/docker compose down >> "$LOG" 2>&1 || echo "[$timestamp] WARN: docker compose down failed" >> "$LOG"
  /usr/bin/docker compose up -d >> "$LOG" 2>&1 || echo "[$timestamp] WARN: docker compose up -d failed" >> "$LOG"

  # Одно короткое уведомление: факт + IP (+ причина)
  send_tg "$MSG"
fi
EOS

chmod +x "$SCRIPT_PATH"

# === Формируем cron-строку с логом ===
if command -v /usr/bin/flock >/dev/null 2>&1; then
  CRON_LINE="*/10 * * * * MODE=$MODE THRESHOLD=$THRESHOLD CPU_THRESHOLD=$CPU_THRESHOLD CPU_WINDOW=$CPU_WINDOW TG_TOKEN=$TG_TOKEN TG_ID=$TG_ID /usr/bin/flock -n /tmp/restart_nexus_on_high_ram.lock $SCRIPT_PATH >> $CRON_LOG 2>&1"
else
  CRON_LINE="*/10 * * * * MODE=$MODE THRESHOLD=$THRESHOLD CPU_THRESHOLD=$CPU_THRESHOLD CPU_WINDOW=$CPU_WINDOW TG_TOKEN=$TG_TOKEN TG_ID=$TG_ID $SCRIPT_PATH >> $CRON_LOG 2>&1"
fi

# === Устанавливаем cron-строку (заменим только нашу) ===
( crontab -l 2>/dev/null | grep -vF "$SCRIPT_PATH" ; echo "$CRON_LINE" ) | crontab -

echo "[install] Cron line installed:"
echo "$CRON_LINE"
echo "[install] Current crontab:"
crontab -l || true

echo "✅ Готово. Тест:"
echo "  MODE=avail THRESHOLD=1 CPU_THRESHOLD=1 $SCRIPT_PATH"
echo "  tail -n 50 $HOME/nexus-docker/restart-on-ram.log"
echo "  tail -n 50 $CRON_LOG"

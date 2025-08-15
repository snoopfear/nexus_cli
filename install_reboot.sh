#!/usr/bin/env bash
set -euo pipefail

# ========= Настройки инсталлятора =========
# Можно переопределить через переменные окружения при запуске:
# TG_TOKEN="..." TG_ID="..." MODE=avail THRESHOLD=95 ./install.sh

TG_TOKEN_DEFAULT="6769297888:AAFOeaKmGtsSSAGsSVGN-x3I1v_VQyh140M"
TG_ID_DEFAULT="257319019"
MODE_DEFAULT="${MODE:-avail}"
THRESHOLD_DEFAULT="${THRESHOLD:-97}"

# Путь до исполняемого скрипта
TARGET_DIR="${HOME}/.local/bin"
SCRIPT_PATH="${TARGET_DIR}/restart_nexus_on_high_ram.sh"

# ========= Создаём скрипт мониторинга =========
mkdir -p "${TARGET_DIR}"

cat > "${SCRIPT_PATH}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# === Настройки (можно переопределять через env/cron) ===
THRESHOLD=${THRESHOLD:-95}          # Порог в %
MODE=${MODE:-avail}                 # raw | avail
LOG="${LOG:-$HOME/nexus-docker/restart-on-ram.log}"

TG_TOKEN="${TG_TOKEN:-__FILL_ME__}"
TG_ID="${TG_ID:-__FILL_ME__}"

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

case "$MODE" in
  raw)   USED_PCT=$RAW_USED_PCT;   METRIC="RAW_USED" ;;
  avail) USED_PCT=$AVAIL_USED_PCT; METRIC="AVAIL_USED" ;;
  *)     USED_PCT=$RAW_USED_PCT;   METRIC="RAW_USED" ;;
esac

timestamp="$(date '+%F %T')"
echo "[$timestamp] RAW_USED=${RAW_USED_PCT}% AVAIL_USED=${AVAIL_USED_PCT}% MODE=${MODE} THRESHOLD=${THRESHOLD}%" >> "$LOG"

if (( USED_PCT >= THRESHOLD )); then
  SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
  MSG="[$timestamp] Перезапуск docker compose из-за высокой RAM (>= ${THRESHOLD}%) на сервере ${SERVER_IP:-unknown}"
  echo "$MSG (metric=${METRIC}, used=${USED_PCT}%)" >> "$LOG"

  cd "$HOME/nexus-docker"
  /usr/bin/docker compose down >> "$LOG" 2>&1 || echo "[$timestamp] WARN: docker compose down failed" >> "$LOG"
  /usr/bin/docker compose up -d >> "$LOG" 2>&1 || echo "[$timestamp] WARN: docker compose up -d failed" >> "$LOG"

  # Короткое Telegram-уведомление: только факт и IP
  if [[ -n "$TG_TOKEN" && -n "$TG_ID" && "$TG_TOKEN" != "__FILL_ME__" ]]; then
    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
         -d chat_id="${TG_ID}" \
         -d text="$MSG" >/dev/null || true
  fi
fi
EOF

# Подклеим в скрипт реальные (или переданные) TG_TOKEN/TG_ID
sed -i "s|__FILL_ME__|${TG_TOKEN_DEFAULT}|g" "${SCRIPT_PATH}"
chmod +x "${SCRIPT_PATH}"

# ========= Добавляем/обновляем cron-задание (без троганья чужих записей) =========
# Строка cron, которую хотим иметь
if command -v /usr/bin/flock >/dev/null 2>&1; then
  CRON_LINE="*/10 * * * * MODE=${MODE_DEFAULT} THRESHOLD=${THRESHOLD_DEFAULT} TG_TOKEN=${TG_TOKEN_DEFAULT} TG_ID=${TG_ID_DEFAULT} /usr/bin/flock -n /tmp/restart_nexus_on_high_ram.lock ${SCRIPT_PATH}"
else
  CRON_LINE="*/10 * * * * MODE=${MODE_DEFAULT} THRESHOLD=${THRESHOLD_DEFAULT} TG_TOKEN=${TG_TOKEN_DEFAULT} TG_ID=${TG_ID_DEFAULT} ${SCRIPT_PATH}"
fi

# Удалим только предыдущие строки именно с нашим скриптом (не затрагивая другие задания)
( crontab -l 2>/dev/null | grep -vF "${SCRIPT_PATH}"; echo "${CRON_LINE}" ) | crontab -

echo "Установка завершена:
- Скрипт: ${SCRIPT_PATH}
- Cron: каждые 10 минут (MODE=${MODE_DEFAULT}, THRESHOLD=${THRESHOLD_DEFAULT})
- Telegram: токен и чатID подставлены.
Проверка вручную:
  MODE=avail THRESHOLD=1 TG_TOKEN='${TG_TOKEN_DEFAULT}' TG_ID='${TG_ID_DEFAULT}' ${SCRIPT_PATH}
Лог:
  tail -n 50 ~/nexus-docker/restart-on-ram.log"

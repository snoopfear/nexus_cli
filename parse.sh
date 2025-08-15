#!/usr/bin/env bash
set -euo pipefail

# ===== Настройки =====
SCREEN_NAME="${SCREEN_NAME:-nexus}"
RETRIES=${RETRIES:-5}
RETRY_DELAY=${RETRY_DELAY:-1}
OUT_CSV="${OUT_CSV:-nexus_stats.csv}"
PREV_FILE="${PREV_FILE:-.prev_tasks.dat}"

declare -A prev_tasks

# Загружаем прошлые значения Tasks, если файл есть
if [[ -f "$PREV_FILE" ]]; then
  while IFS=',' read -r container tasks; do
    prev_tasks["$container"]="$tasks"
  done < "$PREV_FILE"
fi

printf "container,tasks,completed,success\n" > "$OUT_CSV"
printf "%-25s %-12s %-12s %-8s\n" "CONTAINER" "TASKS" "COMPLETED" "SUCCESS"

parse_container() {
  local C="$1"
  local t=""; local cmpl=""; local succ=""

  for ((a=1; a<=RETRIES; a++)); do
    docker exec "$C" bash -lc "
      screen -S '$SCREEN_NAME' -X hardcopy -h /tmp/nexus_snapshot.txt >/dev/null 2>&1 || true
      [ -s /tmp/nexus_snapshot.txt ] || exit 0
    " >/dev/null || true

    t=$(docker exec "$C" bash -lc "grep -Eo 'Tasks:\\s*[0-9]+' /tmp/nexus_snapshot.txt | tail -1 | awk '{print \$2}'" || true)
    cmpl=$(docker exec "$C" bash -lc "grep -Eo 'Completed:\\s*[0-9]+\\s*/\\s*[0-9]+' /tmp/nexus_snapshot.txt | tail -1 | sed -E 's/Completed:\\s*//;s/[[:space:]]//g'" || true)
    succ=$(docker exec "$C" bash -lc "grep -Eo 'Success:\\s*[0-9]+(\\.[0-9]+)?%' /tmp/nexus_snapshot.txt | tail -1 | awk '{print \$2}'" || true)

    if [[ "$t" =~ ^[0-9]+$ ]] && [[ "$cmpl" =~ ^[0-9]+/[0-9]+$ ]] && [[ "$succ" =~ ^[0-9]+(\.[0-9]+)?%$ ]]; then
      break
    fi

    if (( a < RETRIES )); then
      sleep "$RETRY_DELAY"
    fi
  done

  [[ "$t"    =~ ^[0-9]+$             ]] || t="N/A"
  [[ "$cmpl" =~ ^[0-9]+/[0-9]+$      ]] || cmpl="N/A"
  [[ "$succ" =~ ^[0-9]+(\.[0-9]+)?%$ ]] || succ="N/A"

  local diff_str=""
  if [[ "$t" != "N/A" ]]; then
    local prev="${prev_tasks[$C]:-}"
    if [[ "$prev" =~ ^[0-9]+$ ]]; then
      local diff=$(( t - prev ))
      if (( diff > 0 )); then
        diff_str=" (+$diff)"
      elif (( diff < 0 )); then
        diff_str=" ($diff)"
      else
        diff_str=" (+0)"
      fi
    fi
  fi

  printf "%-25s %-12s %-12s %-8s\n" "$C" "$t$diff_str" "$cmpl" "$succ"
  printf "%s,%s,%s,%s\n" "$C" "$t" "$cmpl" "$succ" >> "$OUT_CSV"

  # сохраняем в массив новое значение
  prev_tasks["$C"]="$t"
}

# Обход всех контейнеров node_*
mapfile -t containers < <(docker ps --format '{{.Names}}' | grep -E '^node_' || true)
for C in "${containers[@]}"; do
  parse_container "$C"
done

# Сохраняем новые значения Tasks
: > "$PREV_FILE"
for C in "${!prev_tasks[@]}"; do
  echo "$C,${prev_tasks[$C]}" >> "$PREV_FILE"
done

echo -e "\n✅ Результат сохранён в $OUT_CSV"
echo "💾 Предыдущие значения Tasks сохранены в $PREV_FILE"

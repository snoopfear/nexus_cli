#!/usr/bin/env bash
set -euo pipefail

# ==== НАСТРОЙКИ (можно переопределить через окружение) ====
TG_TOKEN="${TG_TOKEN:-6769297888:AAFOeaKmGtsSSAGsSVGN-x3I1v_VQyh140M}"
TG_ID="${TG_ID:-257319019}"

RAM_THRESHOLD="${RAM_THRESHOLD:-95.0}"
CPU_THRESHOLD="${CPU_THRESHOLD:-97.0}"
CHECK_INTERVAL_SEC="${CHECK_INTERVAL_SEC:-30}"
COOLDOWN_MIN="${COOLDOWN_MIN:-10}"

INSTALL_DIR="/opt/server_monitor"
ENV_FILE="/etc/server-monitor.env"
SERVICE_FILE="/etc/systemd/system/server-monitor.service"
STATE_FILE="$INSTALL_DIR/state.json"

# ==== ПРОВЕРКА ПРАВ ====
if [[ "$EUID" -ne 0 ]]; then
  echo "Пожалуйста, запусти от root: sudo bash install.sh"
  exit 1
fi

echo "[*] Установка зависимостей..."
apt-get update -y
apt-get install -y python3 python3-pip

echo "[*] Создание каталога $INSTALL_DIR ..."
mkdir -p "$INSTALL_DIR"

echo "[*] Развёртывание monitor.py ..."
cat > "$INSTALL_DIR/monitor.py" << 'PY'
#!/usr/bin/env python3
import os, time, json, socket, subprocess
from datetime import datetime, timedelta

RAM_THRESHOLD = float(os.getenv("RAM_THRESHOLD", "95.0"))
CPU_THRESHOLD = float(os.getenv("CPU_THRESHOLD", "97.0"))
CHECK_INTERVAL_SEC = int(os.getenv("CHECK_INTERVAL_SEC", "30"))
COOLDOWN_MIN = int(os.getenv("COOLDOWN_MIN", "10"))
STATE_FILE = os.getenv("STATE_FILE", "/opt/server_monitor/state.json")

TG_TOKEN = os.getenv("TG_TOKEN")
TG_ID = os.getenv("TG_ID")

def _load_state():
    try:
        with open(STATE_FILE, "r") as f:
            return json.load(f)
    except Exception:
        return {}

def _save_state(state):
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, STATE_FILE)

def get_public_ip():
    try:
        import requests
        r = requests.get("https://api.ipify.org", timeout=2)
        if r.ok and r.text.strip():
            return r.text.strip()
    except Exception:
        pass
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        if ip:
            return ip
    except Exception:
        pass
    try:
        out = subprocess.check_output(["hostname", "-I"]).decode().strip()
        if out:
            return out.split()[0]
    except Exception:
        pass
    return "unknown"

def send_telegram(text):
    if not TG_TOKEN or not TG_ID:
        return False
    import requests
    url = f"https://api.telegram.org/bot{TG_TOKEN}/sendMessage"
    payload = {"chat_id": TG_ID, "text": text, "parse_mode": "HTML", "disable_web_page_preview": True}
    try:
        r = requests.post(url, json=payload, timeout=5)
        r.raise_for_status()
        return True
    except Exception as e:
        print(f"[{datetime.utcnow().isoformat()}Z] Telegram send error: {e}")
        return False

def main():
    try:
        import psutil, requests  # noqa: F401
    except ImportError:
        print("psutil/requests not installed. Run: pip3 install psutil requests")
        time.sleep(60)
        return

    state = _load_state()
    last_sent = None
    if state.get("last_sent"):
        try:
            last_sent = datetime.fromisoformat(state["last_sent"])
        except Exception:
            pass

    while True:
        try:
            import psutil
            cpu = psutil.cpu_percent(interval=1.0)
            ram = psutil.virtual_memory().percent
            over_cpu = cpu >= CPU_THRESHOLD
            over_ram = ram >= RAM_THRESHOLD
            now = datetime.utcnow()
            cooldown_ok = True if not last_sent else (now - last_sent >= timedelta(minutes=COOLDOWN_MIN))
            if (over_cpu or over_ram) and cooldown_ok:
                ip = get_public_ip()
                parts = []
                if over_cpu:
                    parts.append(f"CPU: <b>{cpu:.1f}%</b> (порог {CPU_THRESHOLD:.0f}%)")
                if over_ram:
                    parts.append(f"RAM: <b>{ram:.1f}%</b> (порог {RAM_THRESHOLD:.0f}%)")
                msg = ("⚠️ <b>Высокая нагрузка на сервере</b>\n"
                       f"IP: <code>{ip}</code>\n" + "\n".join(parts) + "\n"
                       f"Время (UTC): {now.strftime('%Y-%m-%d %H:%M:%S')}")
                if send_telegram(msg):
                    last_sent = now
                    state["last_sent"] = now.isoformat()
                    _save_state(state)
        except Exception as e:
            print(f"[{datetime.utcnow().isoformat()}Z] monitor loop error: {e}")
        time.sleep(CHECK_INTERVAL_SEC)

if __name__ == "__main__":
    if not TG_TOKEN or not TG_ID:
        print("ERROR: TG_TOKEN/TG_ID env not set")
    main()
PY
chmod +x "$INSTALL_DIR/monitor.py"

echo "[*] Python пакеты..."
python3 -m pip install --upgrade pip
python3 -m pip install psutil requests

echo "[*] Файл окружения $ENV_FILE ..."
cat > "$ENV_FILE" << ENV
TG_TOKEN="$TG_TOKEN"
TG_ID="$TG_ID"
RAM_THRESHOLD="$RAM_THRESHOLD"
CPU_THRESHOLD="$CPU_THRESHOLD"
CHECK_INTERVAL_SEC="$CHECK_INTERVAL_SEC"
COOLDOWN_MIN="$COOLDOWN_MIN"
STATE_FILE="$STATE_FILE"
ENV
chmod 600 "$ENV_FILE"

echo "[*] systemd unit $SERVICE_FILE ..."
cat > "$SERVICE_FILE" << 'UNIT'
[Unit]
Description=Server RAM/CPU monitor with Telegram alerts
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/server-monitor.env
ExecStart=/usr/bin/env python3 /opt/server_monitor/monitor.py
WorkingDirectory=/opt/server_monitor
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
UNIT

echo "[*] Перезапуск systemd и запуск сервиса..."
systemctl daemon-reload
systemctl enable --now server-monitor.service

echo "[*] Короткий статус:"
systemctl --no-pager --lines=10 status server-monitor.service || true

# Опциональное тест-уведомление об установке
if [[ -n "$TG_TOKEN" && -n "$TG_ID" ]]; then
  echo "[*] Отправка тестового уведомления в Telegram..."
  set +e
  curl -fsS -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -H 'Content-Type: application/json' \
    -d "{\"chat_id\":\"${TG_ID}\",\"text\":\"✅ Монитор установлен и запущен.\",\"disable_web_page_preview\":true}" >/dev/null
  set -e
fi

echo
echo "Готово. Логи: journalctl -u server-monitor -f"
echo "Порог RAM=${RAM_THRESHOLD}%, CPU=${CPU_THRESHOLD}%. Меняются в $ENV_FILE и затем: systemctl restart server-monitor"

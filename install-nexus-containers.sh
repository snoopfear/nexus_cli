#!/bin/bash
set -e

# --- Установка зависимостей ---
echo "🔧 Устанавливаем зависимости..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y build-essential pkg-config libssl-dev git-all unzip curl screen protobuf-compiler cargo

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source $HOME/.cargo/env
echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
rustup update

sudo apt remove -y protobuf-compiler
curl -LO https://github.com/protocolbuffers/protobuf/releases/download/v25.2/protoc-25.2-linux-x86_64.zip
unzip -o protoc-25.2-linux-x86_64.zip -d $HOME/.local
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
export PATH="$HOME/.local/bin:$PATH"

# --- Docker и Docker Compose ---
if ! command -v docker &>/dev/null; then
  echo "📦 Устанавливаем Docker..."
  curl -fsSL https://get.docker.com -o get-docker.sh
  sh get-docker.sh
  systemctl enable docker
  systemctl start docker
  rm get-docker.sh
fi

if ! command -v docker-compose &>/dev/null; then
  echo "📦 Устанавливаем docker-compose..."
  DOCKER_COMPOSE_VER="v2.27.0"
  curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VER}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
fi

# --- Установка nexus-network с автосогласием ---
echo "🔨 Качаем и устанавливаем nexus-network..."

sudo apt install -y expect

expect <<EOF
spawn bash -c "curl https://cli.nexus.xyz/ | sh"
expect {
    "Do you agree to the Nexus Beta Terms of Use*" {
        send "y\r"
        exp_continue
    }
    eof
}
EOF

# --- Создание и переход в рабочую директорию ---
DIR="$HOME/nexus-docker"
mkdir -p "$DIR"
cd "$DIR"

# --- Проверка nodeid.txt ---
NODEID_FILE="/root/nodeid.txt"
if [ ! -f "$NODEID_FILE" ]; then
  echo "❌ Не найден $NODEID_FILE"
  exit 1
fi

mapfile -t NODE_IDS < "$NODEID_FILE"
COUNT=${#NODE_IDS[@]}
echo "🔢 Найдено $COUNT node ID"

# --- Dockerfile ---
cat > Dockerfile <<'EOF'
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-c"]

RUN apt update && apt upgrade -y && \
    apt install -y curl unzip libssl-dev screen

COPY nexus-network /usr/local/bin/nexus-network
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /usr/local/bin/nexus-network /entrypoint.sh

CMD ["/entrypoint.sh"]
EOF

# --- Entrypoint для контейнера ---
cat > entrypoint.sh <<'EOF'
#!/bin/bash
set -e

if [ -z "$NODE_ID" ]; then
  echo "❌ NODE_ID не задан в переменных окружения"
  exit 1
fi

echo "▶️ Запускаем screen 'nexus' с NODE_ID=$NODE_ID..."
screen -dmS nexus bash -c "nexus-network start --node-id $NODE_ID"
tail -f /dev/null
EOF

chmod +x entrypoint.sh

# --- Копируем бинарник ---
cp ~/.nexus/bin/nexus-network .

# --- docker-compose.yml ---
echo "version: '3.8'" > docker-compose.yml
echo "services:" >> docker-compose.yml

for i in "${!NODE_IDS[@]}"; do
  NODE_ID="${NODE_IDS[$i]}"
  cat >> docker-compose.yml <<EOF
  "$NODE_ID":
    build: .
    container_name: "$NODE_ID"
    tty: true
    stdin_open: true
    environment:
      - NODE_ID=$NODE_ID
EOF
done

# --- Сборка и запуск ---
echo "🚀 Собираем образы..."
docker-compose build

echo "▶️ Запускаем контейнеры..."
docker-compose up -d

echo ""
echo "✅ Все $COUNT контейнеров запущены и работают в screen-сессиях 'nexus'"
echo "Пример для входа в лог: docker exec -it ${NODE_IDS[0]} screen -r nexus"

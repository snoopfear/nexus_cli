#!/bin/bash
set -e
set -o pipefail

echo "🔧 Устанавливаем зависимости..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y build-essential pkg-config libssl-dev git-all unzip curl screen protobuf-compiler cargo expect git

# Rust (если ещё нет)
if ! command -v cargo &>/dev/null; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  [ -f "$HOME/.cargo/env" ] && source $HOME/.cargo/env
  export PATH="$HOME/.cargo/bin:$PATH"
  echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> ~/.bashrc
fi
[ -f "$HOME/.cargo/env" ] && source $HOME/.cargo/env
export PATH="$HOME/.cargo/bin:$PATH"
rustup update

# Protobuf
sudo apt remove -y protobuf-compiler
curl -LO https://github.com/protocolbuffers/protobuf/releases/download/v25.2/protoc-25.2-linux-x86_64.zip
unzip -o protoc-25.2-linux-x86_64.zip -d $HOME/.local
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
export PATH="$HOME/.local/bin:$PATH"

# Docker
if ! command -v docker &>/dev/null; then
  echo "📦 Устанавливаем Docker..."
  curl -fsSL https://get.docker.com -o get-docker.sh
  sh get-docker.sh
  sudo systemctl enable docker
  sudo systemctl start docker
  rm get-docker.sh
fi

NEXUS_BIN="$HOME/.nexus/bin"
mkdir -p "$NEXUS_BIN"

echo "🔨 Пробуем скачать официальный nexus-network автоинсталлятором..."
cd $HOME
rm -rf ~/.nexus
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

BINARY="$HOME/.nexus/bin/nexus-network"
GLIBC_OK=0
if [ -f "$BINARY" ]; then
  echo "✅ Бинарник скачан. Проверяем совместимость с glibc..."
  if "$BINARY" --help >/dev/null 2>&1; then
    echo "✅ Бинарник рабочий и совместим."
    GLIBC_OK=1
  else
    echo "❌ Бинарник не совместим или не запускается. Будем собирать вручную."
  fi
else
  echo "❌ Не удалось скачать бинарник. Будем собирать вручную."
fi

if [ "$GLIBC_OK" = "0" ]; then
  echo "🔨 Клонируем и собираем nexus-network из исходников..."
  rm -rf nexus-cli
  git clone https://github.com/nexus-xyz/nexus-cli.git
  cd nexus-cli/clients/cli
  cargo build --release
  cp target/release/nexus-network "$NEXUS_BIN/"
  export PATH="$NEXUS_BIN:$PATH"
  echo 'export PATH="$HOME/.nexus/bin:$PATH"' >> ~/.bashrc
fi

# --- Создание и переход в рабочую директорию ---
DIR="$HOME/nexus-docker"
mkdir -p "$DIR"
cd "$DIR"

# --- Проверка nodeid.txt ---
NODEID_FILE="$HOME/nodeid.txt"
if [ ! -f "$NODEID_FILE" ]; then
  echo "❌ Не найден $NODEID_FILE (ожидается в $NODEID_FILE)"
  exit 1
fi

mapfile -t NODE_IDS < <(sed 's/^[ \t]*//;s/[ \t]*$//' "$NODEID_FILE")
COUNT=${#NODE_IDS[@]}
echo "🔢 Найдено $COUNT node ID"

# --- Dockerfile ---
cat > Dockerfile <<'EOF'
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-c"]
RUN apt update && apt upgrade -y && \
    apt install -y curl unzip libssl-dev screen
COPY nexus-network /usr/local/bin/nexus-network
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/nexus-network /entrypoint.sh
CMD ["/entrypoint.sh"]
EOF

# --- Entrypoint ---
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
cp $HOME/.nexus/bin/nexus-network .

# --- docker-compose.yml ---
cat > docker-compose.yml <<EOF
services:
EOF

for i in "${!NODE_IDS[@]}"; do
  NODE_ID="$(echo "${NODE_IDS[$i]}" | xargs)"
  SERVICE_NAME="node_$NODE_ID"
  cat >> docker-compose.yml <<EOF
  $SERVICE_NAME:
    build: .
    container_name: "$SERVICE_NAME"
    tty: true
    stdin_open: true
    environment:
      - NODE_ID=$NODE_ID
EOF
done

# --- Сборка и запуск ---
echo "🚀 Собираем образы..."
docker compose build

echo "▶️ Запускаем контейнеры..."
docker compose up -d

echo ""
echo "✅ Все $COUNT контейнеров запущены и работают в screen-сессиях 'nexus'"
echo "Пример для входа в лог: docker exec -it node_${NODE_IDS[0]} screen -r nexus"

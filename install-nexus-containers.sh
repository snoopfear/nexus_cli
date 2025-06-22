#!/bin/bash
set -e

# --- Базовая установка окружения и инструментов ---
echo "🔧 Устанавливаем зависимости..."

sudo apt update && sudo apt upgrade -y
sudo apt install -y build-essential pkg-config libssl-dev git-all unzip curl screen
sudo apt install -y protobuf-compiler cargo
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

source $HOME/.cargo/env
echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

rustup update

sudo apt remove -y protobuf-compiler
curl -LO https://github.com/protocolbuffers/protobuf/releases/download/v25.2/protoc-25.2-linux-x86_64.zip
unzip protoc-25.2-linux-x86_64.zip -d $HOME/.local
export PATH="$HOME/.local/bin:$PATH"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc

# --- Установка Docker и Docker Compose ---
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

# --- Клонирование nexus и сборка ---
echo "🔨 Качаем и устанавливаем nexus-network..."
curl https://cli.nexus.xyz/ | sh

# --- Создание рабочего каталога ---
DIR="$HOME/nexus-docker"
mkdir -p "$DIR"
cd "$DIR"

read -p "Введите количество контейнеров (по умолчанию 3): " COUNT
COUNT=${COUNT:-3}

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

# --- Скрипт запуска внутри контейнера ---
cat > entrypoint.sh <<'EOF'
#!/bin/bash
set -e

i=$(echo $HOSTNAME | grep -o '[0-9]*$')
NODE_ID=$(sed -n "${i}p" /root/nodeid.txt)

if [ -z "$NODE_ID" ]; then
  echo "❌ Node ID для контейнера $HOSTNAME не найден в /root/nodeid.txt"
  exit 1
fi

screen -dmS nexus bash -c "nexus-network start --node-id $NODE_ID"
tail -f /dev/null
EOF
chmod +x entrypoint.sh

# --- Сохраняем бинарник nexus-network ---
cp ~/.nexus/bin/nexus-network .

# --- docker-compose.yml ---
echo "version: '3.8'" > docker-compose.yml
echo "services:" >> docker-compose.yml

for i in $(seq 1 $COUNT); do
  cat >> docker-compose.yml <<EOF
  nexus$i:
    build: .
    container_name: nexus$i
    tty: true
    stdin_open: true
    volumes:
      - /root/nodeid.txt:/root/nodeid.txt
EOF
done

# --- Сборка и запуск ---
echo "🚀 Собираем образы..."
docker-compose build

echo "▶️ Запускаем контейнеры..."
docker-compose up -d

echo ""
echo "✅ Все $COUNT контейнеров запущены и работают в screen-сессиях 'nexus'"
echo "Проверить логи можно так: docker exec -it nexus1 screen -r nexus"

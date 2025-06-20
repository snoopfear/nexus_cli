#!/bin/bash
set -e

# --- Функция для проверки и установки Docker ---
install_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker не найден. Устанавливаем Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm get-docker.sh
    systemctl enable docker
    systemctl start docker
  else
    echo "Docker уже установлен."
  fi
}

# --- Функция для проверки и установки docker-compose ---
install_docker_compose() {
  if ! command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose не найден. Устанавливаем docker-compose..."
    DOCKER_COMPOSE_VER="v2.27.0"
    curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VER}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
  else
    echo "docker-compose уже установлен."
  fi
}

install_docker
install_docker_compose

# --- Создаём рабочую папку ---
DIR="$HOME/nexus-docker"
mkdir -p "$DIR"
cd "$DIR"

# --- Запрашиваем количество контейнеров ---
read -p "Введите количество контейнеров для запуска (по умолчанию 3): " COUNT
COUNT=${COUNT:-3}

# --- Пишем Dockerfile ---
cat > Dockerfile <<'EOF'
# Stage 1: Builder
FROM ubuntu:24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-c"]

RUN apt update && apt upgrade -y && \
    apt install -y curl unzip build-essential pkg-config libssl-dev git unzip

RUN curl -LO https://github.com/protocolbuffers/protobuf/releases/download/v25.2/protoc-25.2-linux-x86_64.zip && \
    unzip protoc-25.2-linux-x86_64.zip -d /usr/local && \
    rm protoc-25.2-linux-x86_64.zip

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | bash -s -- -y
ENV PATH="/root/.cargo/bin:$PATH"

RUN curl https://cli.nexus.xyz/ | sh

# Stage 2: Final image
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-c"]

RUN apt update && apt upgrade -y && \
    apt install -y curl unzip libssl-dev

COPY --from=builder /root/.nexus/bin/nexus-network /usr/local/bin/nexus-network

ENV PATH="/usr/local/bin:$PATH"

CMD ["bash"]
EOF

# --- Пишем docker-compose.yml ---
echo "version: '3.8'" > docker-compose.yml
echo "services:" >> docker-compose.yml

for i in $(seq 1 $COUNT); do
  cat >> docker-compose.yml <<EOF
  nexus$i:
    build: .
    container_name: nexus$i
    stdin_open: true
    tty: true
EOF
done

# --- Создаём скрипт для сборки ---
cat > build.sh <<'EOF'
#!/bin/bash
docker-compose build
EOF
chmod +x build.sh

echo "Собираем образы..."
./build.sh

echo "Поднимаем контейнеры..."
docker-compose up -d

echo ""
echo "Готово! Контейнеры запущены:"
for i in $(seq 1 $COUNT); do
  echo "  docker exec -it nexus$i bash"
done

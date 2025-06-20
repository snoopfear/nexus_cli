#!/bin/bash

set -e

# Проверка и установка Docker и Docker Compose
install_docker() {
  if ! command -v docker &> /dev/null; then
    echo "Docker не найден. Устанавливаем Docker..."
    sudo apt update
    sudo apt install -y apt-transport-https ca-certificates curl software-properties-common
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt update
    sudo apt install -y docker-ce docker-ce-cli containerd.io
    sudo systemctl enable --now docker
    echo "Docker установлен."
  else
    echo "Docker уже установлен."
  fi

  if ! command -v docker-compose &> /dev/null; then
    echo "Docker Compose не найден. Устанавливаем Docker Compose..."
    # Скачиваем последнюю версию docker-compose
    DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep tag_name | cut -d '"' -f 4)
    sudo curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
    echo "Docker Compose установлен."
  else
    echo "Docker Compose уже установлен."
  fi
}

# Запрос количества контейнеров
read -p "Сколько контейнеров создать? " CONTAINER_COUNT

DIR="$HOME/nexus-docker"
mkdir -p "$DIR"
cd "$DIR"

install_docker

echo "Создаю Dockerfile..."
cat > Dockerfile <<'EOF'
FROM ubuntu:24.04

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

CMD ["bash"]
EOF

echo "Создаю docker-compose.yml..."
cat > docker-compose.yml <<EOF
version: '3.8'

services:
EOF

for ((i=1; i<=CONTAINER_COUNT; i++)); do
  cat >> docker-compose.yml <<EOF
  nexus$i:
    build: .
    container_name: nexus$i
    stdin_open: true
    tty: true

EOF
done

echo "Создаю build.sh..."
cat > build.sh <<'EOF'
#!/bin/bash
docker-compose build
EOF

chmod +x build.sh

echo "Собираю образы..."
./build.sh

echo "Поднимаю контейнеры..."
docker-compose up -d

echo "Готово! Для входа в контейнеры используй, например:"
for ((i=1; i<=CONTAINER_COUNT; i++)); do
  echo "  docker exec -it nexus$i bash"
done

#!/bin/bash

set -e

read -p "Сколько контейнеров создать? " CONTAINER_COUNT

DIR="$HOME/nexus-docker"
mkdir -p "$DIR"
cd "$DIR"

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

for i in $(seq 1 $CONTAINER_COUNT); do
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
echo "  docker exec -it nexus1 bash"

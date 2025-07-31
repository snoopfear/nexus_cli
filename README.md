# nexus_cli

wget -O nexus-cli.sh https://raw.githubusercontent.com/snoopfear/nexus_cli/refs/heads/main/nexus-cli.sh && chmod +x nexus-cli.sh && ./nexus-cli.sh

docker exec -it nexus1 bash

nohup nexus-network start --node-id * > /var/log/nexus.log 2>&1 &

установка через докер по списку

curl -fsSL https://raw.githubusercontent.com/snoopfear/nexus_cli/refs/heads/main/install-nexus-containers.sh -o install-nexus-containers.sh && chmod +x install-nexus-containers.sh && ./install-nexus-containers.sh

nodeid.txt

docker exec -it nexus1 screen -r nexys

fetch ID

bash <(curl -s https://raw.githubusercontent.com/snoopfear/nexus_cli/refs/heads/main/fetch_id.sh)

(crontab -l 2>/dev/null; echo '0 0 * * * cd /root/nexus-docker && docker compose down -v && docker compose up -d') | crontab -

sudo fallocate -l 150G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile

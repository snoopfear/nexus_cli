# nexus_cli

wget -O nexus-cli.sh https://raw.githubusercontent.com/snoopfear/nexus_cli/refs/heads/main/nexus-cli.sh && chmod +x nexus-cli.sh && ./nexus-cli.sh

docker exec -it nexus1 bash

nohup nexus-network start --node-id * > /var/log/nexus.log 2>&1 &

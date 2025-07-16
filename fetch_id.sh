#!/bin/bash
set -e

# 🧹 Очистка предыдущей установки
cd docker-nexus 2>/dev/null && {
  echo "🛑 Останавливаем docker compose..."
  docker compose down || true
  cd ..
  echo "🧼 Удаляем docker-nexus..."
  rm -rf docker-nexus
}
rm -f nodeid.txt /root/nodeid.txt

# 💬 Запрос Ethereum-кошелька
read -p "Введите адрес кошелька (0x...): " WALLET

# 🚫 Валидация адреса
if [[ ! "$WALLET" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
  echo "❌ Неверный формат адреса Ethereum-кошелька"
  exit 1
fi

# 🌐 Запрос JSON-данных
URL="https://production.orchestrator.nexus.xyz/v3/users/$WALLET"
echo "🔍 Загружаем Node ID с Nexus для $WALLET..."

# 📥 Извлекаем все 8-значные числа
NODE_IDS=$(curl -s "$URL" | grep -oE '\b[0-9]{8}\b' | sort -u)

# ❗ Проверка наличия результатов
if [[ -z "$NODE_IDS" ]]; then
  echo "⚠️ Не удалось найти ни одного nodeId. Проверь, что кошелёк корректный и привязан к нодам."
  exit 1
fi

# 💾 Сохраняем
echo "$NODE_IDS" > /root/nodeid.txt

# 📊 Статистика
COUNT=$(echo "$NODE_IDS" | wc -l)
echo "✅ Сохранено $COUNT Node ID в /root/nodeid.txt"

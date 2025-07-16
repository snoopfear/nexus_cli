#!/bin/bash
set -e

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

# 📦 Извлечение nodeId до символа $ из строки вида: 16381650$<UUID>"*<WALLET>
NODE_IDS=$(curl -s "$URL" | grep -oE '[0-9]{8}\$' | sed 's/\$//')

# ❗ Проверка наличия результатов
if [[ -z "$NODE_IDS" ]]; then
  echo "⚠️ Не удалось найти ни одного nodeId. Проверь, что кошелёк корректный и привязан к нодам."
  exit 1
fi

# 💾 Сохраняем в файл
echo "$NODE_IDS" > /root/nodeid.txt

# 📊 Результат
COUNT=$(echo "$NODE_IDS" | wc -l)
echo "✅ Сохранено $COUNT Node ID в /root/nodeid.txt"

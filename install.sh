#!/bin/bash
set -e # Прерывать выполнение при критических ошибках

echo "================================================="
echo "   Автоматическая установка WG-Easy на Debian    "
echo "================================================="
echo ""

# 1. Автоопределение IP и запрос данных
DETECTED_IP=$(curl -s ifconfig.me || echo "")
read -p "Введите публичный IP сервера [$DETECTED_IP]: " INPUT_IP
SERVER_IP=${INPUT_IP:-$DETECTED_IP}

read -p "Придумайте пароль для входа в панель: " WG_PASSWORD
export WG_PASSWORD # Экспортируем, чтобы безопасно передать в Python
echo ""

echo "[1/5] Обновляем систему и устанавливаем зависимости..."
apt update -y > /dev/null 2>&1
apt install -y ca-certificates curl python3-bcrypt > /dev/null 2>&1

echo "[2/5] Проверяем и устанавливаем Docker..."
if ! command -v docker &> /dev/null; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt update -y > /dev/null 2>&1
    apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin > /dev/null 2>&1
else
    echo "      Docker уже установлен, пропускаем..."
fi

echo "[3/5] Генерируем безопасный хеш пароля..."
# Генерируем хеш через Python, считывая пароль напрямую из переменной окружения
RAW_HASH=$(python3 -c "import bcrypt, os; print(bcrypt.hashpw(os.environ['WG_PASSWORD'].encode('utf-8'), bcrypt.gensalt(12)).decode('utf-8'))")

# Важнейший шаг: удваиваем все знаки доллара для Docker Compose
SAFE_HASH="${RAW_HASH//\$/\$\$}"

echo "[4/5] Создаем конфигурационные файлы..."
mkdir -p /opt/wg-easy
cd /opt/wg-easy

cat > docker-compose.yml <<EOF
services:
  wg-easy:
    environment:
      - WG_HOST=$SERVER_IP
      - PASSWORD_HASH=$SAFE_HASH
      - WG_PORT=51820
      - WG_DEFAULT_DNS=1.1.1.1,8.8.8.8
    image: ghcr.io/wg-easy/wg-easy
    container_name: wg-easy
    volumes:
      - ./wireguard:/etc/wireguard
    ports:
      - "51820:51820/udp"
      - "51821:51821/tcp"
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
EOF

echo "[5/5] Запускаем сервер WireGuard..."
docker compose down 2>/dev/null || true
docker compose up -d

echo ""
echo "================================================="
echo " 🎉 УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА! 🎉"
echo "================================================="
echo "🌐 Ссылка на панель: http://$SERVER_IP:51821"
echo "🔑 Ваш пароль:       $WG_PASSWORD"
echo "📂 Рабочая папка:    /opt/wg-easy/"
echo "================================================="
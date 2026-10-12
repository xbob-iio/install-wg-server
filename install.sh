#!/bin/bash
set -e # Прерывать выполнение при критических ошибках

echo "================================================="
echo "   Автоматическая установка WG-Easy на Debian    "
echo "================================================="
echo ""

# 1. Автоопределение IP, сетевого интерфейса и запрос данных
DETECTED_IP=$(curl -s ifconfig.me || echo "")
read -p "Введите публичный IP сервера [$DETECTED_IP]: " INPUT_IP
SERVER_IP=${INPUT_IP:-$DETECTED_IP}

# При host-сети контейнер видит реальный интерфейс хоста (ens3, enp1s0 и т.п.), а не eth0
DETECTED_DEV=$(ip route show default | awk '/default/ {print $5; exit}')
read -p "Внешний сетевой интерфейс [$DETECTED_DEV]: " INPUT_DEV
WG_DEVICE=${INPUT_DEV:-$DETECTED_DEV}

read -p "Придумайте пароль для входа в панель: " WG_PASSWORD
export WG_PASSWORD # Экспортируем, чтобы безопасно передать в Python
echo ""

echo "[1/6] Обновляем систему и устанавливаем зависимости..."
apt update -y > /dev/null 2>&1
apt install -y ca-certificates curl python3-bcrypt iproute2 > /dev/null 2>&1

echo "[2/6] Проверяем и устанавливаем Docker..."
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

echo "[3/6] Настраиваем ядро для максимальной пропускной способности..."
# В режиме host-сети sysctl задаются на самом хосте, а не в контейнере
cat > /etc/sysctl.d/99-wireguard.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.src_valid_mark=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.rmem_default=1048576
net.core.wmem_default=1048576
net.core.netdev_max_backlog=250000
net.ipv4.udp_rmem_min=16384
net.ipv4.udp_wmem_min=16384
net.ipv4.tcp_rmem=4096 1048576 67108864
net.ipv4.tcp_wmem=4096 1048576 67108864
net.ipv4.tcp_mtu_probing=1
EOF
modprobe tcp_bbr 2>/dev/null || true
modprobe wireguard 2>/dev/null || true
sysctl --system > /dev/null 2>&1

echo "[4/6] Генерируем безопасный хеш пароля..."
RAW_HASH=$(python3 -c "import bcrypt, os; print(bcrypt.hashpw(os.environ['WG_PASSWORD'].encode('utf-8'), bcrypt.gensalt(12)).decode('utf-8'))")

# Удваиваем все знаки доллара для Docker Compose
SAFE_HASH="${RAW_HASH//\$/\$\$}"

echo "[5/6] Создаем конфигурационные файлы..."
mkdir -p /opt/wg-easy
cd /opt/wg-easy

cat > docker-compose.yml <<EOF
services:
  wg-easy:
    # Версия 14 — последняя, где работают WG_HOST и PASSWORD_HASH
    image: ghcr.io/wg-easy/wg-easy:14
    container_name: wg-easy
    environment:
      - WG_HOST=$SERVER_IP
      - PASSWORD_HASH=$SAFE_HASH
      - WG_PORT=51820
      - WG_DEVICE=$WG_DEVICE
      - WG_MTU=1420
      - WG_DEFAULT_DNS=1.1.1.1,8.8.8.8
    volumes:
      - ./wireguard:/etc/wireguard
    # Сеть хоста: без моста docker0, NAT и docker-proxy — никаких накладных расходов
    network_mode: host
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    # Без лимитов памяти и CPU (mem_limit / cpus не задаются)
    # Контейнер не будет убит OOM-киллером в первую очередь
    oom_score_adj: -500
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
      memlock: -1
EOF

echo "[6/6] Запускаем сервер WireGuard..."
docker compose down 2>/dev/null || true
docker compose pull
docker compose up -d

echo ""
echo "================================================="
echo " 🎉 УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА! 🎉"
echo "================================================="
echo "🌐 Ссылка на панель: http://$SERVER_IP:51821"
echo "🔑 Ваш пароль:       $WG_PASSWORD"
echo "🔌 Интерфейс:        $WG_DEVICE"
echo "📂 Рабочая папка:    /opt/wg-easy/"
echo "================================================="

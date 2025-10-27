#!/bin/bash
# Синхронный скрипт проверки SNI

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Файлы
SNI_FILE="sni_list.txt"
WORKING_SNI="working_sni.txt"
CONFIG_FILE="xui_reality_config.txt"
SERVER_IP="$1"

# Проверка аргументов
if [ -z "$SERVER_IP" ]; then
    echo -e "${RED}Использование: ./check_sni.sh YOUR_SERVER_IP${NC}"
    echo "Пример: ./check_sni.sh 123.123.123.123"
    echo "Пример2: ./check_sni.sh google.com"
    exit 1
fi

# Проверка существования файла со SNI
if [ ! -f "$SNI_FILE" ]; then
    echo -e "${RED}Файл $SNI_FILE не найден!${NC}"
    echo "Создайте файл sni.txt со списком SNI (каждый на новой строке)"
    exit 1
fi

echo -e "${YELLOW}Начинаю проверку SNI для сервера: $SERVER_IP${NC}"
echo -e "${BLUE}Проверяю оба протокола: HTTP и HTTPS${NC}"
echo "=========================================="

# Очистка старых файлов
> "$WORKING_SNI"
> "$CONFIG_FILE"

# Счетчики
total=0
working_http=0
working_https=0

# Функция проверки HTTP
check_http() {
    local sni=$1
    response=$(curl -I --connect-timeout 3 -m 5 -H "Host: $sni" "http://$SERVER_IP" 2>/dev/null | head -n 1)
    if [[ $response == *"200"* ]] || [[ $response == *"301"* ]] || [[ $response == *"302"* ]] || [[ $response == *"404"* ]]; then
        return 0
    else
        return 1
    fi
}

# Функция проверки HTTPS
check_https() {
    local sni=$1
    response=$(curl -k -I --connect-timeout 3 -m 5 -H "Host: $sni" "https://$SERVER_IP" 2>/dev/null | head -n 1)
    if [[ $response == *"200"* ]] || [[ $response == *"301"* ]] || [[ $response == *"302"* ]] || [[ $response == *"404"* ]]; then
        return 0
    else
        return 1
    fi
}

while read -r sni; do
    # Пропускаем пустые строки
    if [ -z "$sni" ]; then
        continue
    fi

    ((total++))
    echo -n "Проверяю: $sni ... "

    # Проверяем оба протокола
    http_works=0
    https_works=0

    if check_http "$sni"; then
        http_works=1
    fi

    if check_https "$sni"; then
        https_works=1
    fi

    # Определяем результат
    if [ $http_works -eq 1 ] || [ $https_works -eq 1 ]; then
        if [ $http_works -eq 1 ] && [ $https_works -eq 1 ]; then
            echo -e "${GREEN}HTTP+HTTPS${NC}"
            protocol="http+https"
        elif [ $http_works -eq 1 ]; then
            echo -e "${GREEN}HTTP${NC}"
            protocol="http"
            ((working_http++))
        else
            echo -e "${GREEN}HTTPS${NC}"
            protocol="https"
            ((working_https++))
        fi
        echo "$sni|$protocol" >> "$WORKING_SNI"
    else
        echo -e "${RED}НЕ РАБОТАЕТ${NC}"
    fi

    # Пауза между запросами
    sleep 1

done < "$SNI_FILE"

echo "=========================================="
echo -e "${GREEN}Проверка завершена!${NC}"
echo "Всего проверено: $total"
echo -e "Работают по HTTP: ${GREEN}$working_http${NC}"
echo -e "Работают по HTTPS: ${GREEN}$working_https${NC}"

# Создание конфигурации для X-UI
if [ -s "$WORKING_SNI" ]; then
    echo ""
    echo -e "${YELLOW}Создаю конфигурацию для 3X-UI...${NC}"

    # Генерация UUID для VLESS
    UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')")

    # Генерация короткого ID для Reality
    SHORT_ID=$(openssl rand -hex 8 2>/dev/null || head -c 8 /dev/urandom | base64 | tr -d '=')

    # Берем первый рабочий SNI для конфигурации
    FIRST_SNI=$(head -n 1 "$WORKING_SNI" | cut -d'|' -f1)

    # Создание конфигурации Reality
    cat > "$CONFIG_FILE" << EOF
=== РАБОЧИЕ SNI (с протоколами) ===
$(cat "$WORKING_SNI")

=== РЕКОМЕНДАЦИИ ===
- Для Reality лучше использовать SNI, которые работают по HTTPS
- Если HTTPS не работает, но работает HTTP - возможно нужен порт 80
- Reality обычно использует порт 443 (HTTPS)

=== КОНФИГУРАЦИЯ VLESS + REALITY ===

Тип: VLESS + Reality
Адрес: $SERVER_IP
Порт: 443
ID: $UUID
Flow: xtls-rprx-vision
Network: tcp
Security: reality
Reality Опции:
  - publicKey: (сгенерируйте в панели x-ui)
  - shortId: $SHORT_ID
  - spiderX: "/"
  - serverName: $FIRST_SNI
  - fingerprint: chrome

=== ССЫЛКА ДЛЯ КЛИЕНТА ===
vless://$UUID@$SERVER_IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$FIRST_SNI&fp=chrome&pbk=YOUR_PUBLIC_KEY&sid=$SHORT_ID&spx=%2F&type=tcp#Reality-Connection

EOF

    echo -e "${GREEN}Конфигурация сохранена в: $CONFIG_FILE${NC}"
    echo -e "${GREEN}Рабочие SNI сохранены в: $WORKING_SNI${NC}"

    # Показываем лучшие SNI для Reality
    echo ""
    echo -e "${YELLOW}Лучшие SNI для Reality (работают по HTTPS):${NC}"
    grep "https" "$WORKING_SNI" | head -5
else
    echo -e "${RED}Не найдено рабочих SNI! Попробуйте другие домены.${NC}"
fi
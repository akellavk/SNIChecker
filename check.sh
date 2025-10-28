#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Файлы
SNI_FILE="sni.txt"
WORKING_SNI="working_sni.txt"
SERVER_IP="$1"

# Проверка аргументов
if [ -z "$SERVER_IP" ]; then
    echo -e "${RED}Использование: ./check_sni.sh YOUR_SERVER_IP${NC}"
    exit 1
fi

# Проверка существования файла со SNI
if [ ! -f "$SNI_FILE" ]; then
    echo -e "${RED}Файл $SNI_FILE не найден!${NC}"
    echo "Создайте файл sni.txt со списком SNI"
    exit 1
fi

echo -e "${YELLOW}Проверка SNI для сервера: $SERVER_IP${NC}"

# Очистка старых файлов
> "$WORKING_SNI"

# Функция проверки через curl с разными методами
check_sni() {
    local sni=$1
    local methods=("https" "http")

    for method in "${methods[@]}"; do
        if [ "$method" = "https" ]; then
            # Проверка HTTPS с SNI
            response=$(curl -I -k --connect-timeout 10 -m 10 -H "Host: $sni" "https://$SERVER_IP" 2>/dev/null | head -n 1)
        else
            # Проверка HTTP
            response=$(curl -I --connect-timeout 10 -m 10 -H "Host: $sni" "http://$SERVER_IP" 2>/dev/null | head -n 1)
        fi

        if [[ $response == *"200"* ]] || [[ $response == *"301"* ]] || [[ $response == *"302"* ]] || [[ $response == *"404"* ]] || [[ $response == *"403"* ]]; then
            echo "$sni" >> "$WORKING_SNI"
            return 0
        fi
    done

    # Дополнительная проверка через openssl
    if timeout 5 openssl s_client -connect "$SERVER_IP:443" -servername "$sni" -verify_return_error < /dev/null 2>/dev/null | grep -q "Verify return code: 0"; then
        echo "$sni" >> "$WORKING_SNI"
        return 0
    fi

    return 1
}

# Основной цикл проверки
counter=0
working=0

while read -r sni; do
    if [ -z "$sni" ]; then
        continue
    fi

    ((counter++))
    echo -n "Проверяю: $sni ... "

    if check_sni "$sni"; then
        echo -e "${GREEN}РАБОТАЕТ${NC}"
        ((working++))
    else
        echo -e "${RED}НЕ РАБОТАЕТ${NC}"
    fi

    sleep 0.5
done < "$SNI_FILE"

echo "=========================================="
echo -e "${GREEN}Проверка завершена!${NC}"
echo "Всего проверено: $counter"
echo -e "Работающих SNI: ${GREEN}$working${NC}"

if [ $working -gt 0 ]; then
    echo -e "${YELLOW}Рабочие SNI сохранены в: $WORKING_SNI${NC}"
fi
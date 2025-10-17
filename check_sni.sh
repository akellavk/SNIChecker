#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Файлы
SNI_FILE="sni.txt"
WORKING_SNI="working_sni.txt"
CONFIG_FILE="xui_reality_config.txt"
SERVER_IP="$1"
MAX_PARALLEL=5  # Максимальное количество параллельных проверок (можно изменить)

# Проверка аргументов
if [ -z "$SERVER_IP" ]; then
    echo -e "${RED}Использование: ./check_sni.sh YOUR_SERVER_IP [MAX_PARALLEL]${NC}"
    echo "Пример: ./check_sni.sh 123.123.123.123 100"
    exit 1
fi

# Если указан второй аргумент, используем его как MAX_PARALLEL
if [ ! -z "$2" ]; then
    MAX_PARALLEL="$2"
fi

# Проверка существования файла со SNI
if [ ! -f "$SNI_FILE" ]; then
    echo -e "${RED}Файл $SNI_FILE не найден!${NC}"
    echo "Создайте файл sni.txt со списком SNI (каждый на новой строке)"
    exit 1
fi

echo -e "${YELLOW}Начинаю асинхронную проверку SNI для сервера: $SERVER_IP${NC}"
echo -e "${BLUE}Проверяю оба протокола: HTTP и HTTPS (параллельно, макс. $MAX_PARALLEL задач)${NC}"
echo "=========================================="

# Очистка старых файлов
> "$WORKING_SNI"
> "$CONFIG_FILE"

# Файлы для результатов проверок
HTTP_RESULTS="http_results.tmp"
HTTPS_RESULTS="https_results.tmp"
> "$HTTP_RESULTS"
> "$HTTPS_RESULTS"

# Функция для проверки HTTP (запускается в фоне)
check_http() {
    local sni="$1"
    local server_ip="$2"
    local result_file="$3"
    response=$(curl -I --connect-timeout 5 -m 5 -H "Host: $sni" "http://$server_ip" 2>/dev/null | head -n 1)
    if [[ $response == *"200"* ]] || [[ $response == *"301"* ]] || [[ $response == *"302"* ]] || [[ $response == *"404"* ]]; then
        echo "$sni|1" >> "$result_file"
    else
        echo "$sni|0" >> "$result_file"
    fi
}

# Функция для проверки HTTPS (запускается в фоне)
check_https() {
    local sni="$1"
    local server_ip="$2"
    local result_file="$3"
    response=$(curl -k -I --connect-timeout 5 -m 5 -H "Host: $sni" "https://$server_ip" 2>/dev/null | head -n 1)
    if [[ $response == *"200"* ]] || [[ $response == *"301"* ]] || [[ $response == *"302"* ]] || [[ $response == *"404"* ]]; then
        echo "$sni|1" >> "$result_file"
    else
        echo "$sni|0" >> "$result_file"
    fi
}

# Функция для управления параллельными задачами
run_parallel_checks() {
    local sni="$1"
    local server_ip="$2"
    local http_file="$3"
    local https_file="$4"
    local running_count_file="$5"
    local max_parallel="$6"

    # Запускаем HTTP и HTTPS в фоне
    check_http "$sni" "$server_ip" "$http_file" &
    local http_pid=$!
    check_https "$sni" "$server_ip" "$https_file" &
    local https_pid=$!

    # Увеличиваем счетчик запущенных (атомарно)
    echo $(( $(cat "$running_count_file" 2>/dev/null || echo 0) + 2 )) > "$running_count_file"  # +2, т.к. две задачи

    # Ждем, если достигнут лимит (используем [[ ]] для безопасного сравнения)
    while [[ $(cat "$running_count_file" 2>/dev/null || echo 0) -ge $max_parallel ]]; do
        # Ждем завершения любой задачи
        wait -n
        # Уменьшаем счетчик на 1 (поскольку wait -n для одной задачи)
        local current=$(cat "$running_count_file" 2>/dev/null || echo 0)
        echo $(( current - 1 )) > "$running_count_file"
    done
}

# Инициализация файла для счетчика
RUNNING_COUNT="running.tmp"
echo 0 > "$RUNNING_COUNT"

# Обработка SNI в цикле
total=$(wc -l < "$SNI_FILE")
echo "Всего SNI для проверки: $total"
current=0

while read -r sni; do
    # Пропускаем пустые строки
    if [ -z "$sni" ]; then
        continue
    fi

    ((current++))
    echo -n "Запускаю проверку ($current/$total): $sni ... "

    # Запускаем параллельную проверку (СИНХРОННО, без &)
    run_parallel_checks "$sni" "$SERVER_IP" "$HTTP_RESULTS" "$HTTPS_RESULTS" "$RUNNING_COUNT" "$MAX_PARALLEL"

done < "$SNI_FILE"

# Ждем завершения всех фоновых задач (на случай если последние висят)
echo ""
echo -e "${YELLOW}Ожидаю завершения всех проверок...${NC}"
wait

# Обрабатываем результаты без массивов - используем sort и join
sort -t'|' -k1,1 "$HTTP_RESULTS" > sorted_http.tmp
sort -t'|' -k1,1 "$HTTPS_RESULTS" > sorted_https.tmp

# Join по SNI (первый столбец)
join -t'|' -1 1 -2 1 -a 1 -a 2 -e0 sorted_http.tmp sorted_https.tmp > joined_results.tmp

# Подсчет и вывод результатов
working_http=0
working_https=0
total=0

while read -r line; do
    if [ -z "$line" ]; then continue; fi
    sni=$(echo "$line" | cut -d'|' -f1)
    http_works=$(echo "$line" | cut -d'|' -f2)
    https_works=$(echo "$line" | cut -d'|' -f3)

    ((total++))

    if [ "$http_works" -eq 1 ] || [ "$https_works" -eq 1 ]; then
        if [ "$http_works" -eq 1 ] && [ "$https_works" -eq 1 ]; then
            echo -e "${GREEN}HTTP+HTTPS${NC}"
            protocol="http+https"
        elif [ "$http_works" -eq 1 ]; then
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
done < joined_results.tmp

# Очистка временных файлов
rm -f "$HTTP_RESULTS" "$HTTPS_RESULTS" "sorted_http.tmp" "sorted_https.tmp" "joined_results.tmp" "$RUNNING_COUNT"

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
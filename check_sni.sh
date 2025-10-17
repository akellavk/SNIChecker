#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Файлы
SNI_FILE="sni.txt"
WORKING_SNI="working_sni.txt"
CONFIG_FILE="xui_reality_config.txt"
TEMP_SNI="temp_sni.txt"
RESULTS_DIR="check_results"
SERVER_IP="$1"
MAX_JOBS=10  # Максимальное количество параллельных процессов


# Проверка аргументов
if [ -z "$SERVER_IP" ]; then
    echo -e "${RED}Использование: ./check_sni.sh YOUR_SERVER_IP${NC}"
    echo "Пример: ./check_sni.sh 123.123.123.123"
    exit 1
fi

# Создаем директорию для результатов
mkdir -p "$RESULTS_DIR"

# Функция проверки локального файла SNI
check_local_sni() {
    if [ ! -f "$SNI_FILE" ]; then
        echo -e "${RED}Локальный файл $SNI_FILE не найден!${NC}"
        echo "Создайте файл sni_list.txt со списком SNI (каждый на новой строке)"
        echo "Или запустите скрипт при наличии интернета для автоматической загрузки"
        exit 1
    fi

    local count=$(wc -l < "$SNI_FILE" 2>/dev/null || echo 0)
    if [ "$count" -eq 0 ]; then
        echo -e "${RED}Локальный файл $SNI_FILE пустой!${NC}"
        exit 1
    fi

    echo -e "${GREEN}Использую локальный файл: $count SNI${NC}"
}

# Функция проверки одного SNI
check_single_sni() {
    local sni="$1"
    local result_file="$2"

    # Пропускаем пустые строки и комментарии
    if [ -z "$sni" ] || [[ "$sni" == \#* ]]; then
        return
    fi

    # Убираем лишние пробелы
    sni=$(echo "$sni" | xargs)

    # Проверяем HTTP
    local http_works=0
    local https_works=0

    local http_response=$(curl -I --connect-timeout 5 -m 5 -H "Host: $sni" "http://$SERVER_IP" 2>/dev/null | head -n 1)
    if [[ $http_response == *"200"* ]] || [[ $http_response == *"301"* ]] || [[ $http_response == *"302"* ]] || [[ $http_response == *"404"* ]]; then
        http_works=1
    fi

    # Проверяем HTTPS
    local https_response=$(curl -k -I --connect-timeout 5 -m 5 -H "Host: $sni" "https://$SERVER_IP" 2>/dev/null | head -n 1)
    if [[ $https_response == *"200"* ]] || [[ $https_response == *"301"* ]] || [[ $https_response == *"302"* ]] || [[ $https_response == *"404"* ]]; then
        https_works=1
    fi

    # Записываем результат
    if [ $http_works -eq 1 ] || [ $https_works -eq 1 ]; then
        if [ $http_works -eq 1 ] && [ $https_works -eq 1 ]; then
            echo "$sni|http+https" >> "$result_file"
        elif [ $http_works -eq 1 ]; then
            echo "$sni|http" >> "$result_file"
        else
            echo "$sni|https" >> "$result_file"
        fi
    fi
}

# Функция для отображения прогресса
show_progress() {
    local current=$1
    local total=$2
    local width=50
    local percentage=$((current * 100 / total))
    local completed=$((current * width / total))
    local remaining=$((width - completed))

    printf "\r${CYAN}Прогресс: [${GREEN}"
    printf "%*s" $completed | tr ' ' '='
    printf "${CYAN}"
    printf "%*s" $remaining | tr ' ' '-'
    printf "${CYAN}] ${YELLOW}%d%%${CYAN} (%d/%d)${NC}" $percentage $current $total
}

# Основная логика загрузки SNI
echo -e "${YELLOW}Проверка доступности списка SNI...${NC}"

# Используем локальный файл
check_local_sni

echo -e "${YELLOW}Начинаю проверку SNI для сервера: $SERVER_IP${NC}"
echo -e "${BLUE}Проверяю оба протокола: HTTP и HTTPS${NC}"
echo -e "${MAGENTA}Режим: асинхронный (до $MAX_JOBS параллельных проверок)${NC}"
echo "=========================================="

# Очистка старых файлов
> "$WORKING_SNI"
> "$CONFIG_FILE"
rm -f "$RESULTS_DIR"/*.result

# Показываем первые 10 SNI для проверки
echo -e "${CYAN}Первые 10 SNI для проверки:${NC}"
head -10 "$SNI_FILE"
echo "..."

total_sni=$(wc -l < "$SNI_FILE")
current_jobs=0
completed=0

echo -e "${CYAN}Запускаю асинхронную проверку...${NC}"

# Основной цикл асинхронной проверки
while read -r sni; do
    # Пропускаем пустые строки
    if [ -z "$sni" ]; then
        continue
    fi

    # Запускаем проверку в фоне
    check_single_sni "$sni" "$RESULTS_DIR/$sni.result" &

    ((current_jobs++))
    ((completed++))

    # Показываем прогресс
    show_progress $completed $total_sni

    # Если достигли максимума параллельных задач, ждем завершения
    if [ $current_jobs -ge $MAX_JOBS ]; then
        wait -n  # Ждем завершения любой задачи
        ((current_jobs--))
    fi

done < "$SNI_FILE"

# Ждем завершения всех оставшихся задач
echo -e "\n${CYAN}Ожидаю завершения оставшихся проверок...${NC}"
wait

# Собираем все результаты
echo -e "${CYAN}Собираю результаты...${NC}"
for result_file in "$RESULTS_DIR"/*.result; do
    if [ -f "$result_file" ]; then
        cat "$result_file" >> "$WORKING_SNI"
    fi
done

# Статистика
working_http=$(grep -c "|http$" "$WORKING_SNI" 2>/dev/null || echo 0)
working_https=$(grep -c "|https$" "$WORKING_SNI" 2>/dev/null || echo 0)
working_both=$(grep -c "|http+https$" "$WORKING_SNI" 2>/dev/null || echo 0)
total_working=$((working_http + working_https + working_both))

echo "=========================================="
echo -e "${GREEN}Проверка завершена!${NC}"
echo "Всего проверено: $total_sni"
echo -e "Работают по HTTP: ${GREEN}$working_http${NC}"
echo -e "Работают по HTTPS: ${GREEN}$working_https${NC}"
echo -e "Работают по обоим: ${GREEN}$working_both${NC}"
echo -e "Всего рабочих: ${GREEN}$total_working${NC}"

# Создание конфигурации для X-UI
if [ -s "$WORKING_SNI" ]; then
    echo ""
    echo -e "${YELLOW}Создаю конфигурацию для 3X-UI...${NC}"

    # Генерация UUID для VLESS
    UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')")

    # Генерация короткого ID для Reality
    SHORT_ID=$(openssl rand -hex 8 2>/dev/null || head -c 8 /dev/urandom | base64 | tr -d '=')

    # Берем первый рабочий SNI для HTTPS для конфигурации
    FIRST_HTTPS_SNI=$(grep "|https" "$WORKING_SNI" | head -1 | cut -d'|' -f1)

    # Если нет HTTPS, берем первый рабочий SNI
    if [ -z "$FIRST_HTTPS_SNI" ]; then
        FIRST_HTTPS_SNI=$(head -n 1 "$WORKING_SNI" | cut -d'|' -f1)
        echo -e "${YELLOW}Внимание: HTTPS SNI не найдены, использую HTTP SNI: $FIRST_HTTPS_SNI${NC}"
    else
        echo -e "${GREEN}Использую HTTPS SNI: $FIRST_HTTPS_SNI${NC}"
    fi

    # Создание конфигурации Reality
    cat > "$CONFIG_FILE" << EOF
=== РАБОЧИЕ SNI (с протоколами) ===
$(cat "$WORKING_SNI")

=== СТАТИСТИКА ===
Всего проверено: $total_sni
Работают по HTTP: $working_http
Работают по HTTPS: $working_https
Работают по обоим: $working_both
Всего рабочих: $total_working

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
  - serverName: $FIRST_HTTPS_SNI
  - fingerprint: chrome

=== ССЫЛКА ДЛЯ КЛИЕНТА ===
vless://$UUID@$SERVER_IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$FIRST_HTTPS_SNI&fp=chrome&pbk=YOUR_PUBLIC_KEY&sid=$SHORT_ID&spx=%2F&type=tcp#Reality-Connection

EOF

    echo -e "${GREEN}Конфигурация сохранена в: $CONFIG_FILE${NC}"
    echo -e "${GREEN}Рабочие SNI сохранены в: $WORKING_SNI${NC}"

    # Показываем лучшие SNI для Reality
    echo ""
    echo -e "${YELLOW}Лучшие SNI для Reality (работают по HTTPS):${NC}"
    grep "|https" "$WORKING_SNI" | head -10 | while read line; do
        sni_name=$(echo "$line" | cut -d'|' -f1)
        echo "  - $sni_name"
    done

else
    echo -e "${RED}Не найдено рабочих SNI!${NC}"
    echo "Возможные причины:"
    echo "1. Сервер $SERVER_IP не доступен"
    echo "2. Порты 80/443 закрыты"
    echo "3. На сервере не запущен веб-сервер"
    echo "4. Все SNI заблокированы оператором"
fi

# Очистка временных файлов
if [ -f "$TEMP_SNI" ]; then
    rm -f "$TEMP_SNI"
fi
rm -rf "$RESULTS_DIR"

echo -e "${GREEN}Асинхронная проверка завершена!${NC}"
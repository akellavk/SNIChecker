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
SERVER_IP="$1"
MAX_JOBS=5  # Уменьшаем для стабильности
BATCH_SIZE=1000  # Проверяем по частям

# Проверка аргументов
if [ -z "$SERVER_IP" ]; then
    echo -e "${RED}Использование: ./check_sni.sh YOUR_SERVER_IP${NC}"
    echo "Пример: ./check_sni.sh 123.123.123.123"
    exit 1
fi

# Функция проверки локального файла SNI
check_local_sni() {
    if [ ! -f "$SNI_FILE" ]; then
        echo -e "${RED}Локальный файл $SNI_FILE не найден!${NC}"
        exit 1
    fi

    local count=$(wc -l < "$SNI_FILE" 2>/dev/null || echo 0)
    if [ "$count" -eq 0 ]; then
        echo -e "${RED}Локальный файл $SNI_FILE пустой!${NC}"
        exit 1
    fi

    echo -e "${GREEN}Обнаружено SNI: $count${NC}"
    echo -e "${YELLOW}Рекомендуется проверить только первые 1000-5000 SNI${NC}"
}

# Функция проверки одного SNI
check_single_sni() {
    local sni="$1"

    # Пропускаем пустые строки
    if [ -z "$sni" ] || [[ "$sni" == \#* ]]; then
        return
    fi

    # Убираем лишние пробелы
    sni=$(echo "$sni" | xargs)

    # Проверяем HTTP
    local http_works=0
    local https_works=0

    # Более быстрая проверка с меньшим таймаутом
    local http_response=$(curl -s -I --connect-timeout 3 -m 3 -H "Host: $sni" "http://$SERVER_IP" 2>/dev/null | head -n 1)
    if [[ $http_response == *"200"* ]] || [[ $http_response == *"301"* ]] || [[ $http_response == *"302"* ]] || [[ $http_response == *"404"* ]]; then
        http_works=1
    fi

    # Проверяем HTTPS только если HTTP не сработал (экономия времени)
    if [ $http_works -eq 0 ]; then
        local https_response=$(curl -s -k -I --connect-timeout 3 -m 3 -H "Host: $sni" "https://$SERVER_IP" 2>/dev/null | head -n 1)
        if [[ $https_response == *"200"* ]] || [[ $https_response == *"301"* ]] || [[ $https_response == *"302"* ]] || [[ $https_response == *"404"* ]]; then
            https_works=1
        fi
    fi

    # Возвращаем результат
    if [ $http_works -eq 1 ]; then
        echo "$sni|http"
    elif [ $https_works -eq 1 ]; then
        echo "$sni|https"
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

# Основная логика
echo -e "${YELLOW}Проверка доступности списка SNI...${NC}"
check_local_sni

total_sni=$(wc -l < "$SNI_FILE")
echo -e "${RED}ВНИМАНИЕ: Найдено $total_sni SNI${NC}"
echo -e "${YELLOW}Это займет очень много времени!${NC}"

# Спросим пользователя, сколько проверять
read -p "Сколько SNI проверить? (рекомендуется 100-1000): " check_count
check_count=${check_count:-1000}

if [ $check_count -gt $total_sni ]; then
    check_count=$total_sni
fi

echo -e "${GREEN}Будет проверено: $check_count SNI${NC}"
echo -e "${YELLOW}Начинаю проверку для сервера: $SERVER_IP${NC}"
echo -e "${MAGENTA}Режим: асинхронный (до $MAX_JOBS параллельных проверок)${NC}"
echo "=========================================="

# Очистка старых файлов
> "$WORKING_SNI"
> "$CONFIG_FILE"

# Создаем временный файл с ограниченным количеством SNI
head -n $check_count "$SNI_FILE" > "$SNI_FILE.tmp"

# Основной цикл асинхронной проверки
current_jobs=0
completed=0
total_to_check=$check_count

echo -e "${CYAN}Запускаю асинхронную проверку...${NC}"

# Используем именованные пайпы для лучшего управления
temp_pipe=$(mktemp -u)
mkfifo "$temp_pipe"
exec 3<> "$temp_pipe"

# Заполняем пайп
while read -r sni; do
    echo "$sni" >&3
done < "$SNI_FILE.tmp"

# Запускаем рабочие процессы
for ((i=0; i<MAX_JOBS; i++)); do
    (
        while read -r sni <&3; do
            result=$(check_single_sni "$sni")
            if [ -n "$result" ]; then
                echo "$result" >> "$WORKING_SNI"
            fi
            # Обновляем прогресс
            flock 200
            completed=$((completed + 1))
            show_progress $completed $total_to_check
            flock -u 200
        done
    ) &
done

# Ждем завершения
wait

# Закрываем пайп
exec 3>&-
rm -f "$temp_pipe"
rm -f "$SNI_FILE.tmp"

echo -e "\n${CYAN}Завершаю проверку...${NC}"

# Статистика
working_http=$(grep -c "|http$" "$WORKING_SNI" 2>/dev/null || echo 0)
working_https=$(grep -c "|https$" "$WORKING_SNI" 2>/dev/null || echo 0)
working_both=$(grep -c "|http+https$" "$WORKING_SNI" 2>/dev/null || echo 0)
total_working=$((working_http + working_https))

echo "=========================================="
echo -e "${GREEN}Проверка завершена!${NC}"
echo "Всего проверено: $completed"
echo -e "Работают по HTTP: ${GREEN}$working_http${NC}"
echo -e "Работают по HTTPS: ${GREEN}$working_https${NC}"
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
=== РАБОЧИЕ SNI (первые 20) ===
$(head -20 "$WORKING_SNI")

=== СТАТИСТИКА ===
Всего проверено: $completed
Работают по HTTP: $working_http
Работают по HTTPS: $working_https
Всего рабочих: $total_working

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
    echo -e "${GREEN}Все рабочие SNI сохранены в: $WORKING_SNI${NC}"

    # Показываем лучшие SNI для Reality
    echo ""
    echo -e "${YELLOW}Лучшие SNI для Reality (работают по HTTPS):${NC}"
    grep "|https" "$WORKING_SNI" | head -10 | while read line; do
        sni_name=$(echo "$line" | cut -d'|' -f1)
        echo "  - $sni_name"
    done

else
    echo -e "${RED}Не найдено рабочих SNI!${NC}"
fi

echo -e "${GREEN}Асинхронная проверка завершена!${NC}"
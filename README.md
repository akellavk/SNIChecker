# Использование для ПК


```bash
# Клонирование репозитория
git clone https://github.com/akellavk/SNIChecker.git

# Создание виртуального окружения
python -m venv .venv

# Активация виртуального окружения
source .venv/bin/activate

# Установка пакетов
pip install -r requirements.txt
```

Отредактировать файл vless_tcp_reality.py, указав свои IP и Порт inbound

```bash
# Запускаем скрипт
python vless_tcp_reality.py
```

# Использование для Android (Termux)

```bash
# Клонирование репозитория
git clone https://github.com/akellavk/SNIChecker.git

# Переход в директорию проекта
cd SNIChecker

# Разрешение на выполнение скрипта
chmod +x check_sni.sh

# Установка необходимых пакетов
pkg install python git curl

# Создание виртуального окружения (шаг можно пропустить, если не нужно виртуальное окружение)
python -m venv .venv

# Активация виртуального окружения (шаг можно пропустить, если не создали виртуальное окружение)
source .venv/bin/activate

# Установка пакетов
pip install -r requirements.txt

# Отредактировать файл vless_tcp_reality.py, указав свои IP и Порт inbound
nano vless_tcp_reality.py

# Запускаем скрипт
python check_sni.py google.com
# или
python vless_tcp_reality.py --host google.com
```
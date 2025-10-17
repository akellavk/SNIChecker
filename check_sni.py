#!/usr/bin/env python3
import asyncio
import aiohttp
import sys
import os
from datetime import datetime
import random
import uuid
import secrets


class Color:
    RED = '\033[91m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    BLUE = '\033[94m'
    CYAN = '\033[96m'
    MAGENTA = '\033[95m'
    RESET = '\033[0m'


class SNIChecker:
    def __init__(self, server_ip, max_concurrent=50):
        self.server_ip = server_ip
        self.max_concurrent = max_concurrent
        self.sni_file = "sni.txt"
        self.working_file = "working_sni.txt"
        self.config_file = "xui_reality_config.txt"

        self.working_sni = []
        self.total_checked = 0
        self.completed = 0


    async def check_single_sni(self, session, sni):
        """Проверяет один SNI асинхронно"""
        if not sni or sni.startswith('#'):
            return None

        sni = sni.strip()
        if not sni:
            return None

        protocols = []

        try:
            # Проверка HTTP
            async with session.get(f"http://{self.server_ip}", headers={"Host": sni},
                    timeout=aiohttp.ClientTimeout(total=5), ssl=False) as response:
                if response.status in [200, 301, 302, 404]:
                    protocols.append("http")
        except:
            pass

        try:
            # Проверка HTTPS
            async with session.get(f"https://{self.server_ip}", headers={"Host": sni},
                    timeout=aiohttp.ClientTimeout(total=5), ssl=False) as response:
                if response.status in [200, 301, 302, 404]:
                    protocols.append("https")
        except:
            pass

        if protocols:
            return sni, protocols
        return None


    async def worker(self, session, queue, progress_queue):
        """Рабочий процесс для проверки SNI"""
        while True:
            try:
                sni = await queue.get()
                if sni is None:
                    break

                result = await self.check_single_sni(session, sni)
                await progress_queue.put(1)

                if result:
                    self.working_sni.append(result)

            except Exception as e:
                print(f"{Color.RED}Ошибка при проверке {sni}: {e}{Color.RESET}")
            finally:
                queue.task_done()


    async def update_progress(self, total, progress_queue):
        """Обновляет прогресс-бар"""
        start_time = datetime.now()

        while self.completed < total:
            # Ждем обновления прогресса
            try:
                await asyncio.wait_for(progress_queue.get(), timeout=0.1)
                self.completed += 1
                progress_queue.task_done()
            except asyncio.TimeoutError:
                continue

            # Обновляем прогресс каждые 100 проверок или чаще
            if self.completed % 100 == 0 or self.completed == total:
                elapsed = (datetime.now() - start_time).total_seconds()
                speed = self.completed / elapsed if elapsed > 0 else 0
                eta = (total - self.completed) / speed if speed > 0 else 0

                self.print_progress(self.completed, total, speed, eta)

        print()  # Новая строка после завершения


    def print_progress(self, current, total, speed, eta):
        """Выводит красивый прогресс-бар"""
        width = 50
        percent = current / total
        completed_width = int(width * percent)
        remaining_width = width - completed_width

        progress_bar = f"{Color.GREEN}{'█' * completed_width}{Color.CYAN}{'░' * remaining_width}{Color.RESET}"
        percent_display = f"{percent:.1%}"

        # Форматируем ETA
        if eta > 3600:
            eta_str = f"{eta / 3600:.1f}ч"
        elif eta > 60:
            eta_str = f"{eta / 60:.1f}м"
        else:
            eta_str = f"{eta:.0f}с"

        print(f"\r{Color.CYAN}Прогресс: [{progress_bar}] {Color.YELLOW}{percent_display} "
              f"{Color.CYAN}({current}/{total}) | {speed:.1f} SNI/сек | ETA: {eta_str}{Color.RESET}", end="",
            flush=True)


    async def run_check(self):
        """Основная функция проверки"""
        print(f"{Color.YELLOW}Загружаю список SNI...{Color.RESET}")

        if not os.path.exists(self.sni_file):
            print(f"{Color.RED}Файл {self.sni_file} не найден!{Color.RESET}")
            return

        with open(self.sni_file, 'r', encoding='utf-8') as f:
            sni_list = [line.strip() for line in f if line.strip()]

        total_sni = len(sni_list)
        print(f"{Color.GREEN}Найдено SNI: {total_sni}{Color.RESET}")

        if total_sni == 0:
            print(f"{Color.RED}Файл SNI пустой!{Color.RESET}")
            return

        # Показываем первые 10 SNI
        print(f"{Color.CYAN}Первые 10 SNI для проверки:{Color.RESET}")
        for i, sni in enumerate(sni_list[:10]):
            print(f"  {i + 1}. {sni}")
        print("...")

        print(f"{Color.YELLOW}Начинаю асинхронную проверку для сервера: {self.server_ip}{Color.RESET}")
        print(f"{Color.MAGENTA}Режим: асинхронный (до {self.max_concurrent} параллельных проверок){Color.RESET}")
        print("=" * 60)

        # Очищаем старые файлы
        open(self.working_file, 'w').close()
        open(self.config_file, 'w').close()

        # Создаем очереди
        queue = asyncio.Queue()
        progress_queue = asyncio.Queue()

        # Заполняем очередь SNI
        for sni in sni_list:
            await queue.put(sni)

        # Создаем ограничитель соединений
        connector = aiohttp.TCPConnector(limit=self.max_concurrent, limit_per_host=self.max_concurrent)

        async with aiohttp.ClientSession(connector=connector) as session:
            # Запускаем прогресс-бар
            progress_task = asyncio.create_task(self.update_progress(total_sni, progress_queue))

            # Запускаем рабочих
            workers = [asyncio.create_task(self.worker(session, queue, progress_queue)) for _ in
                range(self.max_concurrent)]

            # Ждем завершения очереди
            await queue.join()

            # Останавливаем рабочих
            for _ in range(self.max_concurrent):
                await queue.put(None)

            await asyncio.gather(*workers)

            # Ждем завершения прогресс-бара
            await progress_task

        print(f"{Color.GREEN}Проверка завершена!{Color.RESET}")

        # Сохраняем результаты
        self.save_results()

        # Создаем конфигурацию
        self.create_config()


    def save_results(self):
        """Сохраняет рабочие SNI"""
        with open(self.working_file, 'w', encoding='utf-8') as f:
            for sni, protocols in self.working_sni:
                protocol_str = "+".join(protocols)
                f.write(f"{sni}|{protocol_str}\n")

        total_working = len(self.working_sni)
        http_count = sum(1 for _, protocols in self.working_sni if "http" in protocols)
        https_count = sum(1 for _, protocols in self.working_sni if "https" in protocols)

        print(f"{Color.GREEN}Всего проверено: {self.completed}{Color.RESET}")
        print(f"{Color.GREEN}Работают по HTTP: {http_count}{Color.RESET}")
        print(f"{Color.GREEN}Работают по HTTPS: {https_count}{Color.RESET}")
        print(f"{Color.GREEN}Всего рабочих: {total_working}{Color.RESET}")


    def create_config(self):
        """Создает конфигурацию для X-UI"""
        if not self.working_sni:
            print(f"{Color.RED}Не найдено рабочих SNI!{Color.RESET}")
            return

        # Ищем лучший SNI (предпочтительно HTTPS)
        https_sni = next((sni for sni, protocols in self.working_sni if "https" in protocols), None)
        first_sni = https_sni if https_sni else self.working_sni[0][0]

        # Генерируем UUID и Short ID
        vless_uuid = str(uuid.uuid4())
        short_id = secrets.token_hex(4)

        # Создаем список рабочих SNI для вывода
        sni_list_text = ""
        for sni, protocols in self.working_sni[:50]:
            protocol_str = "+".join(protocols)
            sni_list_text += f"{sni}|{protocol_str}\n"

        config_content = f"""=== РАБОЧИЕ SNI (первые 50) ===
{sni_list_text}
=== СТАТИСТИКА ===
Всего проверено: {self.completed}
Всего рабочих: {len(self.working_sni)}
Работают по HTTP: {sum(1 for _, protocols in self.working_sni if "http" in protocols)}
Работают по HTTPS: {sum(1 for _, protocols in self.working_sni if "https" in protocols)}

=== КОНФИГУРАЦИЯ VLESS + REALITY ===

Тип: VLESS + Reality
Адрес: {self.server_ip}
Порт: 443
ID: {vless_uuid}
Flow: xtls-rprx-vision
Network: tcp
Security: reality
Reality Опции:
  - publicKey: (сгенерируйте в панели x-ui)
  - shortId: {short_id}
  - spiderX: "/"
  - serverName: {first_sni}
  - fingerprint: chrome

=== ССЫЛКА ДЛЯ КЛИЕНТА ===
vless://{vless_uuid}@{self.server_ip}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni={first_sni}&fp=chrome&pbk=YOUR_PUBLIC_KEY&sid={short_id}&spx=%2F&type=tcp#Reality-Connection
"""

        with open(self.config_file, 'w', encoding='utf-8') as f:
            f.write(config_content)

        print(f"{Color.GREEN}Конфигурация сохранена в: {self.config_file}{Color.RESET}")
        print(f"{Color.GREEN}Рабочие SNI сохранены в: {self.working_file}{Color.RESET}")

        # Показываем лучшие SNI
        https_snis = [sni for sni, protocols in self.working_sni if "https" in protocols][:10]
        if https_snis:
            print(f"\n{Color.YELLOW}Лучшие SNI для Reality (HTTPS):{Color.RESET}")
            for sni in https_snis:
                print(f"  {Color.GREEN}✓{Color.RESET} {sni}")


async def main():
    if len(sys.argv) != 2:
        print(f"{Color.RED}Использование: python check_sni.py YOUR_SERVER_IP{Color.RESET}")
        print(f"{Color.RED}Пример: python check_sni.py 123.123.123.123{Color.RESET}")
        sys.exit(1)

    server_ip = sys.argv[1]

    # Настраиваем количество параллельных запросов
    max_concurrent = 50  # Можно увеличить до 200-500 на быстрых соединениях

    checker = SNIChecker(server_ip, max_concurrent)

    try:
        await checker.run_check()
    except KeyboardInterrupt:
        print(f"\n{Color.YELLOW}Проверка прервана пользователем{Color.RESET}")
    except Exception as e:
        print(f"{Color.RED}Критическая ошибка: {e}{Color.RESET}")


if __name__ == "__main__":
    # Для Windows нужно использовать специальный event loop
    if sys.platform == "win32":
        asyncio.set_event_loop_policy(asyncio.WindowsProactorEventLoopPolicy())

    asyncio.run(main())
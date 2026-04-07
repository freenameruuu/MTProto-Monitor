# MTProto Monitor

Веб-дашборд для мониторинга активных подключений к MTProto-прокси. Собирает данные каждую минуту через cron, хранит историю за 30 дней и отображает красивую аналитику в браузере.

![License](https://img.shields.io/badge/license-MIT-blue) ![Docker](https://img.shields.io/badge/docker-required-blue) ![Python](https://img.shields.io/badge/python-3.12-blue)

---

## Возможности

- **Live-счётчик** — текущее количество соединений обновляется каждые 30 секунд
- **График по часам** — история подключений за 1, 3 или 7 дней
- **Тепловая карта** — активность по дням недели и часам суток
- **Пиковые часы** — топ-8 самых загруженных часов
- **KPI-карточки** — сейчас активно / пик / среднее в час / точек собрано
- **Тёмная и светлая тема** — переключается одной кнопкой
- **Ротация логов** — хранит последние 43 200 точек (~30 дней при сборе раз в минуту)

## Архитектура

```
cron (каждую минуту)
  └─ collect.sh → docker exec mtproto ss -tn → /var/log/mtproto_conns.log

mtproto-monitor (Docker)
  ├─ main.py (FastAPI + uvicorn, порт 8080)
  │    ├─ GET /api/current   — живое число соединений
  │    ├─ GET /api/stats     — агрегированная статистика
  │    └─ GET /api/history   — сырые точки за N часов
  └─ static/index.html      — фронтенд (Chart.js)
```

## Требования

| Компонент | Версия |
|-----------|--------|
| Linux (Debian/Ubuntu/CentOS) | — |
| Docker Engine | ≥ 20.x |
| Docker Compose | v2 (`docker compose`) |
| MTProto-прокси | контейнер с именем **`mtproto`** |

> Скрипт должен запускаться от **root** (нужен доступ к Docker и cron).

## Быстрый старт

```bash
# Скачай и запусти одной командой
curl -fsSL https://raw.githubusercontent.com/freenameruuu/MTProto-Monitor/main/setup.sh | sudo bash
```

или вручную:

```bash
git clone https://github.com/freenameruuu/MTProto-Monitor.git
cd MTProto-Monitor
sudo bash setup.sh
```

После завершения установки дашборд доступен по адресу:

```
http://<IP-сервера>:8080
```

## Что делает установочный скрипт

1. Проверяет наличие Docker и контейнера `mtproto`
2. Создаёт директорию `/opt/mtproto-monitor/`
3. Генерирует `collect.sh` — скрипт сбора данных
4. Генерирует `main.py` — FastAPI-бэкенд
5. Генерирует `Dockerfile` и `docker-compose.yml`
6. Создаёт фронтенд `static/index.html`
7. Добавляет задачу в **cron** (каждую минуту)
8. Собирает и запускает Docker-контейнер `mtproto-monitor`

## Структура файлов после установки

```
/opt/mtproto-monitor/
├── collect.sh          # Скрипт сбора данных (запускается cron)
├── main.py             # FastAPI-бэкенд
├── Dockerfile
├── docker-compose.yml
└── static/
    └── index.html      # Фронтенд дашборда

/var/log/mtproto_conns.log   # Лог данных (timestamp,count)
```

## Полезные команды

```bash
# Просмотр логов бэкенда
docker logs mtproto-monitor -f

# Просмотр сырых данных
tail -f /var/log/mtproto_conns.log

# Перезапуск бэкенда
cd /opt/mtproto-monitor && docker compose restart

# Проверка API вручную
curl http://localhost:8080/api/current
curl http://localhost:8080/api/stats?days=7
curl http://localhost:8080/api/history?hours=24
```

## API

### `GET /api/current`
Возвращает текущее число активных соединений.

```json
{ "timestamp": 1712500000, "connections": 42 }
```

### `GET /api/stats?days=7`
Агрегированная статистика за `days` дней.

```json
{
  "hourly": { "2024-04-07 14:00": 38, "...": "..." },
  "heatmap": { "Пн": [0, 2, 1, ...], "...": [] },
  "kpi": {
    "current": 42,
    "avg_per_hour": 25,
    "max": 110,
    "max_ts": 1712412000,
    "total_points": 10080,
    "days": 7
  }
}
```

### `GET /api/history?hours=24`
Сырые точки за последние `hours` часов.

```json
{ "data": [{ "ts": 1712499940, "count": 38 }, "..."] }
```

## Настройка

Переменные в начале `setup.sh` можно изменить перед запуском:

| Переменная | По умолчанию | Описание |
|---|---|---|
| `CONTAINER_NAME` | `mtproto` | Имя Docker-контейнера прокси |
| `PORT` | `443` | Порт, на котором слушает прокси |
| `SERVICE_PORT` | `8080` | Порт дашборда |
| `LOG_FILE` | `/var/log/mtproto_conns.log` | Путь к файлу лога |
| `INSTALL_DIR` | `/opt/mtproto-monitor` | Директория установки |

## Лицензия

MIT

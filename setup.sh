#!/bin/bash
# =============================================================
# MTProto Monitor — установочный скрипт
# Запуск: sudo bash setup.sh
# =============================================================
set -e

INSTALL_DIR="/opt/mtproto-monitor"
LOG_FILE="/var/log/mtproto_conns.log"
CONTAINER_NAME="mtproto"
PORT=443
SERVICE_PORT=8080
CRON_JOB="* * * * * /opt/mtproto-monitor/collect.sh >> /var/log/mtproto_conns_cron.log 2>&1"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

echo -e "${CYAN}"
cat << 'BANNER'
  __  __ _____ ___           _          __  __             _ _
 |  \/  |_   _| _ \_ __ ___| |_ ___   |  \/  |___ _ _  _(_) |_ ___ _ _
 | |\/| | | | |  _/ '_/ _ \  _/ _ \  | |\/| / _ \ ' \| | |  _/ _ \ '_|
 |_|  |_| |_| |_| |_| \___/\__\___/  |_|  |_\___/_||_|_|_|\__\___/_|
BANNER
echo -e "${NC}"
info "Установка MTProto Monitor..."
echo ""

# ---- 0. Root check ----
[[ $EUID -ne 0 ]] && error "Запусти скрипт от root: sudo bash setup.sh"

# ---- 1. Docker check ----
if ! command -v docker &>/dev/null; then
    error "Docker не найден. Установи его сначала: https://docs.docker.com/engine/install/"
fi
success "Docker найден: $(docker --version | head -1)"

# ---- 2. Проверяем контейнер mtproto ----
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    warn "Контейнер '${CONTAINER_NAME}' не запущен. Сбор данных начнётся когда он появится."
else
    success "Контейнер '${CONTAINER_NAME}' запущен"
fi

# ---- 3. Создаём директорию ----
info "Создаю ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}/static"

# ---- 4. Создаём collect.sh ----
info "Создаю скрипт сбора данных..."
cat > "${INSTALL_DIR}/collect.sh" << COLLECT
#!/bin/bash
CONTAINER="${CONTAINER_NAME}"
PORT=${PORT}
LOG="${LOG_FILE}"

COUNT=\$(docker exec "\$CONTAINER" ss -tn 2>/dev/null | grep ":\${PORT}" | wc -l)
echo "\$(date +%s),\${COUNT}" >> "\$LOG"

# Ротация: 30 дней (43200 строк)
LINES=\$(wc -l < "\$LOG" 2>/dev/null || echo 0)
if [ "\$LINES" -gt 43200 ]; then
    tail -n 43200 "\$LOG" > "\${LOG}.tmp" && mv "\${LOG}.tmp" "\$LOG"
fi
COLLECT
chmod +x "${INSTALL_DIR}/collect.sh"
success "collect.sh создан"

# ---- 5. Создаём main.py ----
info "Создаю FastAPI бэкенд..."
cat > "${INSTALL_DIR}/main.py" << 'PYEOF'
#!/usr/bin/env python3
import subprocess, time
from datetime import datetime
from pathlib import Path
from collections import defaultdict
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

LOG_FILE = Path("/var/log/mtproto_conns.log")
CONTAINER_NAME = "mtproto"
PORT = 443

app = FastAPI()
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

def get_current_connections() -> int:
    try:
        result = subprocess.run(
            ["docker", "exec", CONTAINER_NAME, "ss", "-tn"],
            capture_output=True, text=True, timeout=5
        )
        return sum(1 for line in result.stdout.splitlines() if f":{PORT}" in line)
    except Exception:
        return 0

def parse_log(days: int = 7) -> list:
    if not LOG_FILE.exists():
        return []
    cutoff = time.time() - days * 86400
    entries = []
    with open(LOG_FILE) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ts, count = line.split(",", 1)
                ts, count = int(ts), int(count)
                if ts >= cutoff:
                    entries.append({"ts": ts, "count": count})
            except ValueError:
                continue
    return entries

def aggregate_by_hour(entries):
    buckets = defaultdict(list)
    for e in entries:
        dt = datetime.fromtimestamp(e["ts"])
        key = dt.strftime("%Y-%m-%d %H:00")
        buckets[key].append(e["count"])
    return {k: round(sum(v)/len(v)) for k, v in sorted(buckets.items())}

def aggregate_heatmap(entries):
    day_names = ["Пн","Вт","Ср","Чт","Пт","Сб","Вс"]
    buckets = defaultdict(lambda: defaultdict(list))
    for e in entries:
        dt = datetime.fromtimestamp(e["ts"])
        day = day_names[dt.weekday()]
        buckets[day][dt.hour].append(e["count"])
    return {
        day: [round(sum(buckets[day][h])/len(buckets[day][h])) if buckets[day][h] else 0 for h in range(24)]
        for day in day_names
    }

@app.get("/api/current")
def current():
    return {"timestamp": int(time.time()), "connections": get_current_connections()}

@app.get("/api/stats")
def stats(days: int = 7):
    entries = parse_log(days)
    if not entries:
        return {"hourly": {}, "heatmap": {}, "kpi": {}}
    hourly = aggregate_by_hour(entries)
    heatmap = aggregate_heatmap(entries)
    counts = [e["count"] for e in entries]
    max_idx = counts.index(max(counts))
    return {
        "hourly": hourly,
        "heatmap": heatmap,
        "kpi": {
            "current": get_current_connections(),
            "avg_per_hour": round(sum(counts) / max(len(counts), 1)),
            "max": max(counts),
            "max_ts": entries[max_idx]["ts"],
            "total_points": len(entries),
            "days": days,
        }
    }

@app.get("/api/history")
def history(hours: int = 24):
    entries = parse_log(days=1)
    cutoff = time.time() - hours * 3600
    return {"data": [e for e in entries if e["ts"] >= cutoff]}

app.mount("/", StaticFiles(directory="static", html=True), name="static")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8080, reload=False)
PYEOF
success "main.py создан"

# ---- 6. Создаём Dockerfile ----
info "Создаю Dockerfile..."
cat > "${INSTALL_DIR}/Dockerfile" << 'DEOF'
FROM python:3.12-slim
WORKDIR /app
RUN apt-get update && apt-get install -y curl && \
    curl -fsSL https://download.docker.com/linux/static/stable/x86_64/docker-27.3.1.tgz | \
    tar xz --strip-components=1 -C /usr/local/bin docker/docker && \
    apt-get remove -y curl && apt-get autoclean && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir fastapi "uvicorn[standard]"
COPY main.py .
COPY static/ static/
EXPOSE 8080
CMD ["python", "main.py"]
DEOF

# ---- 7. Создаём docker-compose.yml ----
cat > "${INSTALL_DIR}/docker-compose.yml" << DCEOF
services:
  monitor:
    build: .
    container_name: mtproto-monitor
    restart: unless-stopped
    ports:
      - "127.0.0.1:${SERVICE_PORT}:8080"
    group_add:
      - "999"
    volumes:
      - ${LOG_FILE}:${LOG_FILE}:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./static:/app/static:ro
    environment:
      - TZ=Europe/Moscow
DCEOF
success "Dockerfile и docker-compose.yml созданы"

# ---- 8. Создаём фронтенд ----
info "Создаю фронтенд (index.html)..."
cat > "${INSTALL_DIR}/static/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru" data-theme="dark">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>MTProto Monitor</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
//api.fontshare.com/v2/css?f[]=satoshi@400,500,700&display=swap" rel="stylesheet">
<style>
:root,[data-theme="light"]{--color-bg:#f7f6f2;--color-surface:#f9f8f5;--color-surface-2:#fbfbf9;--color-surface-offset:#f3f0ec;--color-border:#d4d1ca;--color-text:#28251d;--color-text-muted:#7a7974;--color-text-faint:#bab9b4;--color-primary:#01696f;--color-success:#437a22;--color-error:#a12c7b;--shadow-sm:0 1px 2px oklch(0.2 0.01 80/0.06);--shadow-md:0 4px 12px oklch(0.2 0.01 80/0.08);--font-body:'Satoshi',sans-serif;--text-xs:clamp(0.75rem,.7rem + .25vw,.875rem);--text-sm:clamp(0.875rem,.8rem + .35vw,1rem);--text-base:clamp(1rem,.95rem + .25vw,1.125rem);--text-lg:clamp(1.125rem,1rem + .75vw,1.5rem);--text-xl:clamp(1.5rem,1.2rem + 1.25vw,2.25rem);--space-1:.25rem;--space-2:.5rem;--space-3:.75rem;--space-4:1rem;--space-5:1.25rem;--space-6:1.5rem;--space-8:2rem;--radius-md:.5rem;--radius-lg:.75rem;--radius-xl:1rem;--transition:180ms cubic-bezier(.16,1,.3,1)}
[data-theme="dark"]{--color-bg:#171614;--color-surface:#1c1b19;--color-surface-2:#201f1d;--color-surface-offset:#1d1c1a;--color-border:#393836;--color-text:#cdccca;--color-text-muted:#797876;--color-text-faint:#5a5957;--color-primary:#4f98a3;--color-success:#6daa45;--color-error:#d163a7;--shadow-sm:0 1px 2px oklch(0 0 0/.2);--shadow-md:0 4px 12px oklch(0 0 0/.3)}
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
html{-webkit-font-smoothing:antialiased}
body{min-height:100dvh;font-family:var(--font-body,sans-serif);font-size:var(--text-base);color:var(--color-text);background:var(--color-bg);line-height:1.6}
button{cursor:pointer;background:none;border:none;font:inherit;color:inherit}
.app{display:grid;grid-template-rows:auto 1fr;min-height:100dvh}
.header{background:var(--color-surface);border-bottom:1px solid var(--color-border);padding:var(--space-4) var(--space-8);display:flex;align-items:center;justify-content:space-between;gap:var(--space-4);position:sticky;top:0;z-index:10}
.logo{display:flex;align-items:center;gap:var(--space-2);font-weight:700;font-size:var(--text-lg)}
.badge{font-size:var(--text-xs);padding:.2em .6em;border-radius:99px;background:color-mix(in oklch,var(--color-primary) 15%,var(--color-surface));color:var(--color-primary);font-weight:500}
.header-right{display:flex;align-items:center;gap:var(--space-4)}
.status-dot{width:8px;height:8px;border-radius:50%;background:var(--color-success);box-shadow:0 0 6px var(--color-success);animation:pulse 2s ease-in-out infinite;display:inline-block}
.status-dot.error{background:var(--color-error);box-shadow:0 0 6px var(--color-error)}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.4}}
.status-label{font-size:var(--text-xs);color:var(--color-text-muted);display:flex;align-items:center;gap:var(--space-2)}
.btn-icon{display:flex;align-items:center;justify-content:center;width:36px;height:36px;border-radius:var(--radius-md);color:var(--color-text-muted);transition:background var(--transition),color var(--transition)}
.btn-icon:hover{background:var(--color-surface
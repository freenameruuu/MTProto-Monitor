#!/bin/bash
# =============================================================
# MTProto Monitor — установочный скрипт
# Запуск: bash setup.sh
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
<link href="https://api.fontshare.com/v2/css?f[]=satoshi@400,500,700&display=swap" rel="stylesheet">
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
.btn-icon:hover{background:var(--color-surface-offset);color:var(--color-text)}
.main{padding:var(--space-8);display:flex;flex-direction:column;gap:var(--space-6);max-width:1400px;margin:0 auto;width:100%}
.kpi-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(min(200px,100%),1fr));gap:var(--space-4)}
.kpi-card{background:var(--color-surface);border:1px solid oklch(from var(--color-text) l c h/.08);border-radius:var(--radius-xl);padding:var(--space-5) var(--space-6);box-shadow:var(--shadow-sm)}
.kpi-label{font-size:var(--text-xs);color:var(--color-text-muted);text-transform:uppercase;letter-spacing:.06em;font-weight:500;margin-bottom:var(--space-2)}
.kpi-value{font-size:var(--text-xl);font-weight:700;font-variant-numeric:tabular-nums lining-nums;line-height:1.1;min-height:2.2rem;display:flex;align-items:center}
.kpi-delta{font-size:var(--text-xs);color:var(--color-text-muted);margin-top:var(--space-1);font-variant-numeric:tabular-nums}
.delta-up{color:var(--color-success)}.delta-down{color:var(--color-error)}
.charts-grid{display:grid;grid-template-columns:2fr 1fr;gap:var(--space-6)}
@media(max-width:900px){.charts-grid{grid-template-columns:1fr}}
.chart-card{background:var(--color-surface);border:1px solid oklch(from var(--color-text) l c h/.08);border-radius:var(--radius-xl);padding:var(--space-6);box-shadow:var(--shadow-sm)}
.chart-header{display:flex;align-items:flex-start;justify-content:space-between;margin-bottom:var(--space-5);gap:var(--space-4)}
.chart-title{font-size:var(--text-base);font-weight:600}
.chart-subtitle{font-size:var(--text-xs);color:var(--color-text-muted);margin-top:2px}
.chart-wrap{position:relative;height:260px}
.period-tabs{display:flex;gap:var(--space-1);background:var(--color-surface-offset);border-radius:var(--radius-md);padding:3px;flex-shrink:0}
.period-tab{font-size:var(--text-xs);padding:.3em .8em;border-radius:calc(var(--radius-md) - 3px);color:var(--color-text-muted);font-weight:500;cursor:pointer;transition:background var(--transition),color var(--transition)}
.period-tab.active{background:var(--color-surface);color:var(--color-text);box-shadow:var(--shadow-sm)}
.heatmap-container{display:grid;grid-template-columns:40px 1fr;gap:var(--space-2)}
.heatmap-days{display:flex;flex-direction:column;gap:2px}
.heat-row-label{font-size:var(--text-xs);color:var(--color-text-faint);display:flex;align-items:center;justify-content:flex-end;padding-right:var(--space-2);height:22px}
.heatmap-grid-row{display:grid;grid-template-columns:repeat(24,1fr);gap:2px}
.heat-cell{height:22px;border-radius:3px;background:var(--color-surface-offset);cursor:pointer;transition:transform .12s ease;position:relative}
.heat-cell:hover{transform:scale(1.3);z-index:1}
.hour-labels{display:grid;grid-template-columns:40px repeat(24,1fr);gap:2px;margin-top:var(--space-2)}
.hour-label{font-size:9px;color:var(--color-text-faint);text-align:center}
.peak-list{display:flex;flex-direction:column;gap:var(--space-2);margin-top:var(--space-4)}
.peak-item{display:flex;align-items:center;gap:var(--space-3)}
.peak-label{font-size:var(--text-xs);color:var(--color-text-muted);width:70px;flex-shrink:0}
.peak-bar-wrap{flex:1;background:var(--color-surface-offset);border-radius:99px;height:6px;overflow:hidden}
.peak-bar{height:100%;border-radius:99px;background:var(--color-primary);transition:width .6s cubic-bezier(.16,1,.3,1)}
.peak-val{font-size:var(--text-xs);color:var(--color-text);font-variant-numeric:tabular-nums;width:36px;text-align:right;flex-shrink:0}
.tooltip{position:fixed;background:var(--color-surface-2);border:1px solid var(--color-border);border-radius:var(--radius-md);padding:var(--space-2) var(--space-3);font-size:var(--text-xs);box-shadow:var(--shadow-md);pointer-events:none;z-index:100;display:none;white-space:nowrap}
.error-banner{background:color-mix(in oklch,var(--color-error) 12%,var(--color-surface));border:1px solid color-mix(in oklch,var(--color-error) 30%,var(--color-surface));border-radius:var(--radius-lg);padding:var(--space-4) var(--space-6);font-size:var(--text-sm);color:var(--color-text-muted);display:none}
.error-banner.visible{display:block}
@media(max-width:600px){.header{padding:var(--space-3) var(--space-4)}.main{padding:var(--space-4)}}
</style>
</head>
<body>
<div class="app">
  <header class="header">
    <div style="display:flex;align-items:center;gap:var(--space-3)">
      <div class="logo">
        <svg width="28" height="28" viewBox="0 0 28 28" fill="none"><rect width="28" height="28" rx="7" fill="var(--color-primary)" opacity=".15"/><path d="M7 14 L11 10 L14 13 L18 8 L21 14" stroke="var(--color-primary)" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" fill="none"/><circle cx="14" cy="19" r="2.5" fill="var(--color-primary)"/></svg>
        MTProto Monitor
      </div>
      <span class="badge">live</span>
    </div>
    <div class="header-right">
      <span class="status-label"><span class="status-dot" id="statusDot"></span><span id="statusText">Подключение...</span></span>
      <button class="btn-icon" id="themeToggle" aria-label="Тема"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/></svg></button>
    </div>
  </header>
  <main class="main">
    <div class="error-banner" id="errorBanner">⚠️ Нет ответа от API. Проверь что бэкенд запущен: <code>docker compose up -d</code></div>
    <div class="kpi-grid">
      <div class="kpi-card"><div class="kpi-label">Сейчас активно</div><div class="kpi-value" id="kpiNow">—</div><div class="kpi-delta" id="kpiNowDelta">обновляется...</div></div>
      <div class="kpi-card"><div class="kpi-label">Пик за период</div><div class="kpi-value" id="kpiMax">—</div><div class="kpi-delta" id="kpiMaxTime">—</div></div>
      <div class="kpi-card"><div class="kpi-label">Среднее / час</div><div class="kpi-value" id="kpiAvg">—</div><div class="kpi-delta" id="kpiAvgSub">за 7 дней</div></div>
      <div class="kpi-card"><div class="kpi-label">Точек собрано</div><div class="kpi-value" id="kpiPoints">—</div><div class="kpi-delta" id="kpiPointsSub">из лога</div></div>
    </div>
    <div class="charts-grid">
      <div class="chart-card">
        <div class="chart-header">
          <div><div class="chart-title">Коннекты по часам</div><div class="chart-subtitle" id="lineSubtitle">Загрузка...</div></div>
          <div class="period-tabs"><button class="period-tab active" data-days="7">7д</button><button class="period-tab" data-days="3">3д</button><button class="period-tab" data-days="1">1д</button></div>
        </div>
        <div class="chart-wrap"><canvas id="lineChart"></canvas></div>
      </div>
      <div class="chart-card">
        <div class="chart-header"><div><div class="chart-title">По времени суток</div><div class="chart-subtitle">Доля активности</div></div></div>
        <div class="chart-wrap"><canvas id="donutChart"></canvas></div>
      </div>
    </div>
    <div class="charts-grid">
      <div class="chart-card">
        <div class="chart-header"><div><div class="chart-title">Тепловая карта</div><div class="chart-subtitle">День × час, среднее за 7 дней</div></div></div>
        <div id="heatmapWrap"></div>
        <div class="hour-labels" id="hourLabelWrap"></div>
      </div>
      <div class="chart-card">
        <div class="chart-header"><div><div class="chart-title">Топ пиковых часов</div><div class="chart-subtitle">Среднее за 7 дней</div></div></div>
        <div class="peak-list" id="peakList"></div>
      </div>
    </div>
  </main>
</div>
<div class="tooltip" id="tooltip"></div>
<script>
const DAY_NAMES=['Пн','Вт','Ср','Чт','Пт','Сб','Вс'];
const SLOT_LABELS=['Ночь 0–6','Утро 6–12','День 12–18','Вечер 18–24'];
let currentDays=7,statsCache=null,lineChart=null,donutChart=null;
const $=id=>document.getElementById(id);
const isDark=()=>document.documentElement.getAttribute('data-theme')==='dark';
const gridColor=()=>isDark()?'rgba(255,255,255,0.06)':'rgba(0,0,0,0.06)';
const textColor=()=>isDark()?'#797876':'#7a7974';
const primaryColor=()=>isDark()?'#4f98a3':'#01696f';
const fmt=n=>Number(n).toLocaleString('ru');
const fmtTs=ts=>{const d=new Date(ts*1000);return d.toLocaleString('ru',{day:'2-digit',month:'2-digit',hour:'2-digit',minute:'2-digit'});};
async function fetchStats(days){const r=await fetch(`/api/stats?days=${days}`);if(!r.ok)throw new Error(r.status);return r.json();}
async function fetchCurrent(){const r=await fetch('/api/current');if(!r.ok)throw new Error(r.status);return r.json();}
function setConnected(ok){const dot=$('statusDot'),txt=$('statusText'),banner=$('errorBanner');if(ok){dot.className='status-dot';txt.textContent='Онлайн';banner.classList.remove('visible');}else{dot.className='status-dot error';txt.textContent='Нет связи';banner.classList.add('visible');}}
function renderKPI(kpi){const now=kpi.current??0,avg=kpi.avg_per_hour??0;$('kpiNow').textContent=fmt(now);$('kpiNowDelta').textContent=now>avg?`▲ выше среднего (${avg})`:`▼ ниже среднего (${avg})`;$('kpiNowDelta').className='kpi-delta '+(now>avg?'delta-up':'delta-down');$('kpiMax').textContent=fmt(kpi.max??0);$('kpiMaxTime').textContent=kpi.max_ts?`пик ${fmtTs(kpi.max_ts)}`:'—';$('kpiAvg').textContent=fmt(avg);$('kpiAvgSub').textContent=`за ${kpi.days??7} дней`;$('kpiPoints').textContent=fmt(kpi.total_points??0);$('kpiPointsSub').textContent=`≈${Math.round((kpi.total_points||0)/Math.max(kpi.days||7,1))} в день`;}
function buildLineChart(hourly){const labels=Object.keys(hourly),values=Object.values(hourly);const ctx=$('lineChart').getContext('2d');const grad=ctx.createLinearGradient(0,0,0,260);grad.addColorStop(0,isDark()?'rgba(79,152,163,.3)':'rgba(1,105,111,.2)');grad.addColorStop(1,'rgba(0,0,0,0)');if(lineChart)lineChart.destroy();lineChart=new Chart(ctx,{type:'line',data:{labels,datasets:[{data:values,borderColor:primaryColor(),backgroundColor:grad,borderWidth:2,pointRadius:0,pointHoverRadius:5,pointHoverBackgroundColor:primaryColor(),tension:0.35,fill:true}]},options:{responsive:true,maintainAspectRatio:false,plugins:{legend:{display:false},tooltip:{mode:'index',intersect:false,backgroundColor:isDark()?'#201f1d':'#f9f8f5',titleColor:isDark()?'#cdccca':'#28251d',bodyColor:isDark()?'#797876':'#7a7974',borderColor:isDark()?'#393836':'#d4d1ca',borderWidth:1,callbacks:{label:ctx=>`${ctx.parsed.y} коннектов`,title:(items)=>items[0].label||''}}},scales:{x:{grid:{color:gridColor()},ticks:{color:textColor(),font:{size:11},maxRotation:0,autoSkip:true,maxTicksLimit:10,callback(v,i){const l=this.getLabelForValue(i);return l&&l.includes('00:')?l.split(' ')[1]||l:''}}},y:{grid:{color:gridColor()},ticks:{color:textColor(),font:{size:11}},beginAtZero:true}},interaction:{mode:'nearest',axis:'x',intersect:false}}});}
function buildDonut(hourly){const keys=Object.keys(hourly),vals=Object.values(hourly),slots=[0,0,0,0];keys.forEach((k,i)=>{const h=parseInt((k.split(' ')[1]||'').split(':')[0])||0;slots[Math.floor(h/6)]+=vals[i];});const colors=isDark()?['#5591c7','#4f98a3','#e8af34','#fdab43']:['#006494','#01696f','#d19900','#da7101'];if(donutChart)donutChart.destroy();donutChart=new Chart($('donutChart').getContext('2d'),{type:'doughnut',data:{labels:SLOT_LABELS,datasets:[{data:slots,backgroundColor:colors,borderColor:isDark()?'#1c1b19':'#f9f8f5',borderWidth:3,hoverOffset:6}]},options:{responsive:true,maintainAspectRatio:false,cutout:'65%',plugins:{legend:{position:'bottom',labels:{color:textColor(),font:{size:12},padding:14,boxWidth:12,boxHeight:12}},tooltip:{backgroundColor:isDark()?'#201f1d':'#f9f8f5',titleColor:isDark()?'#cdccca':'#28251d',bodyColor:isDark()?'#797876':'#7a7974',borderColor:isDark()?'#393836':'#d4d1ca',borderWidth:1,callbacks:{label:ctx=>{const t=ctx.dataset.data.reduce((a,b)=>a+b,0)||1;return ` ${fmt(ctx.parsed)} (${Math.round(ctx.parsed/t*100)}%)`;}}}}}})}
function buildHeatmap(heatmap){const wrap=$('heatmapWrap');wrap.innerHTML='';const maxVal=Math.max(...DAY_NAMES.flatMap(d=>heatmap[d]||Array(24).fill(0)));function heatColor(v){const t=maxVal>0?v/maxVal:0;if(isDark())return `rgb(${Math.round(t*79+30)},${Math.round(t*152+40)},${Math.round(t*163+50)})`;return `rgb(${Math.round(220+t*(1-220))},${Math.round(220+t*(105-220))},${Math.round(240+t*(111-240))})`;}
const container=document.createElement('div');container.className='heatmap-container';const daysCol=document.createElement('div');daysCol.className='heatmap-days';const rowsCol=document.createElement('div');rowsCol.style.cssText='display:flex;flex-direction:column;gap:2px';DAY_NAMES.forEach(day=>{const lbl=document.createElement('div');lbl.className='heat-row-label';lbl.textContent=day;daysCol.appendChild(lbl);const row=document.createElement('div');row.className='heatmap-grid-row';const dayData=heatmap[day]||Array(24).fill(0);dayData.forEach((v,h)=>{const cell=document.createElement('div');cell.className='heat-cell';cell.style.background=heatColor(v);const tip=$('tooltip');cell.addEventListener('mousemove',e=>{tip.style.display='block';tip.style.left=(e.clientX+12)+'px';tip.style.top=(e.clientY-8)+'px';tip.innerHTML=`<b>${day} ${String(h).padStart(2,'0')}:00</b><br>среднее: ${v} коннектов`;});cell.addEventListener('mouseleave',()=>{tip.style.display='none';});row.appendChild(cell);});rowsCol.appendChild(row);});container.appendChild(daysCol);container.appendChild(rowsCol);wrap.appendChild(container);const lblRow=$('hourLabelWrap');lblRow.innerHTML='';const spacer=document.createElement('div');spacer.style.cssText='width:40px;flex-shrink:0';lblRow.appendChild(spacer);for(let h=0;h<24;h++){const el=document.createElement('div');el.className='hour-label';el.textContent=h%3===0?String(h).padStart(2,'0'):'';lblRow.appendChild(el);}}
function buildPeakList(heatmap){const hourTotals=Array.from({length:24},(_,h)=>({h,v:DAY_NAMES.reduce((s,d)=>s+(heatmap[d]?.[h]||0),0)})).sort((a,b)=>b.v-a.v);const maxV=hourTotals[0]?.v||1;const list=$('peakList');list.innerHTML='';hourTotals.slice(0,8).forEach(({h,v})=>{const item=document.createElement('div');item.className='peak-item';item.innerHTML=`<div class="peak-label">${String(h).padStart(2,'0')}:00–${String(h+1).padStart(2,'0')}:00</div><div class="peak-bar-wrap"><div class="peak-bar" style="width:${Math.round(v/maxV*100)}%"></div></div><div class="peak-val">${fmt(v)}</div>`;list.appendChild(item);});}
async function loadStats(days){try{const stats=await fetchStats(days);statsCache=stats;setConnected(true);renderKPI(stats.kpi||{});buildLineChart(stats.hourly||{});buildDonut(stats.hourly||{});buildHeatmap(stats.heatmap||{});buildPeakList(stats.heatmap||{});$('lineSubtitle').textContent=`${Object.keys(stats.hourly||{}).length} часовых точек за ${days} дней`;}catch(e){setConnected(false);}}
async function refreshCurrent(){try{const d=await fetchCurrent();setConnected(true);if(statsCache?.kpi){statsCache.kpi.current=d.connections;renderKPI(statsCache.kpi);}else{$('kpiNow').textContent=fmt(d.connections);}}catch(e){setConnected(false);}}
document.querySelectorAll('.period-tab').forEach(btn=>{btn.addEventListener('click',()=>{document.querySelectorAll('.period-tab').forEach(b=>b.classList.remove('active'));btn.classList.add('active');currentDays=parseInt(btn.dataset.days);loadStats(currentDays);});});
$('themeToggle').addEventListener('click',()=>{const root=document.documentElement;const next=root.getAttribute('data-theme')==='dark'?'light':'dark';root.setAttribute('data-theme',next);if(statsCache){buildLineChart(statsCache.hourly||{});buildDonut(statsCache.hourly||{});buildHeatmap(statsCache.heatmap||{});}});
loadStats(currentDays);
setInterval(refreshCurrent,30000);
setInterval(()=>loadStats(currentDays),300000);
</script>
</body>
</html>
HTMLEOF
success "index.html создан"

# ---- 9. Создаём файл лога ----
touch "${LOG_FILE}"
chmod 666 "${LOG_FILE}"
success "Лог файл: ${LOG_FILE}"

# ---- 10. Добавляем cron ----
info "Настраиваю cron..."
# Убираем старую запись если есть, добавляем новую
(crontab -l 2>/dev/null | grep -v "mtproto-monitor/collect.sh"; echo "${CRON_JOB}") | crontab -
success "Cron настроен (каждую минуту)"

# ---- 11. Собираем и запускаем docker-compose ----
info "Собираю Docker образ..."
cd "${INSTALL_DIR}"

if docker compose version &>/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif docker-compose version &>/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    error "docker compose не найден. Установи Docker Compose v2."
fi

$COMPOSE_CMD up -d --build

success "Контейнер mtproto-monitor запущен"

# ---- 12. Первый тест ----
sleep 3
info "Проверяю API..."
if curl -sf "http://localhost:${SERVICE_PORT}/api/current" > /dev/null; then
    success "API отвечает на http://localhost:${SERVICE_PORT}"
else
    warn "API пока не отвечает — подожди 5-10 секунд и попробуй снова"
fi

# ---- Итог ----
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Установка завершена!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  📊 Дашборд (локально): ${CYAN}http://localhost:${SERVICE_PORT}${NC}"
echo -e "  🔐 Через SSH-туннель: ${CYAN}ssh -L ${SERVICE_PORT}:localhost:${SERVICE_PORT} ubuntu@<SERVER_IP_OR_HOSTNAME>${NC}"
echo -e "  📁 Файлы:      ${CYAN}${INSTALL_DIR}${NC}"
echo -e "  📝 Лог данных: ${CYAN}${LOG_FILE}${NC}"
echo -e "  ⏱  Cron:       каждую минуту собирает коннекты"
echo ""
echo -e "  Полезные команды:"
echo -e "  ${YELLOW}docker logs mtproto-monitor -f${NC}   — логи бэкенда"
echo -e "  ${YELLOW}tail -f ${LOG_FILE}${NC}    — сырые данные"
echo -e "  ${YELLOW}cd ${INSTALL_DIR} && docker compose restart${NC}"
echo ""

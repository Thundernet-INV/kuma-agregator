#!/usr/bin/env bash
set -euo pipefail

# ===== util =====
timestamp() { date +%Y%m%d-%H%M%S; }
backup_if_exists() {
  local f="$1"
  if [[ -f "$f" ]]; then
    local b="${f}.bak-$(timestamp)"
    echo "  - Existe ${f}. Haciendo backup en ${b}"
    cp "$f" "$b"
  fi
}
ensure_dir() {
  local d="$1"
  [[ -d "$d" ]] || { echo "  - Creando dir: $d"; mkdir -p "$d"; }
}
detect_pkg_manager() {
  if [[ -f "yarn.lock" ]]; then echo "yarn"; return
  elif [[ -f "pnpm-lock.yaml" ]]; then echo "pnpm"; return
  else echo "npm"; return
  fi
}
install_deps() {
  local pm="$1"; shift
  local deps=("$@")
  echo "📦 Instalando dependencias: ${deps[*]}"
  case "$pm" in
    npm) npm install "${deps[@]}";;
    yarn) yarn add "${deps[@]}";;
    pnpm) pnpm add "${deps[@]}";;
  esac
}
append_gitignore() {
  local line="$1"
  if [[ -f ".gitignore" ]]; then
    if ! grep -qxF "$line" .gitignore; then
      echo "$line" >> .gitignore
      echo "  - Añadido a .gitignore: $line"
    fi
  else
    echo "$line" > .gitignore
    echo "  - Creado .gitignore con: $line"
  fi
}
npm_set_script() {
  local key="$1" val="$2"
  if command -v npm >/dev/null 2>&1; then
    if npm --version >/dev/null 2>&1; then
      if npm pkg set "scripts.$key=$val" >/dev/null 2>&1; then
        echo "  - Añadido script npm: $key"
        return 0
      fi
    fi
  fi
  echo "  ! No pude añadir script npm automáticamente. Agrega en package.json -> scripts: \"$key\": \"$val\""
  return 1
}

# ===== prechecks =====
if [[ ! -f "package.json" ]]; then
  echo "❌ No se encontró package.json en el directorio actual."
  echo "Colócate en la raíz del proyecto (donde está package.json) y vuelve a ejecutar."
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "❌ Node.js no está instalado o no está en PATH."
  exit 1
fi

echo "🔎 Detectando gestor de paquetes..."
PKG_MANAGER=$(detect_pkg_manager)
echo "   -> $PKG_MANAGER"

# ===== preguntas =====
echo ""
echo "¿Cómo quieres instalar el endpoint de history?"
select MODE in "Standalone (crear servidor Express nuevo)" "Integración (solo agregar módulos y te doy el snippet)"; do
  case $REPLY in
    1) MODE="standalone"; break;;
    2) MODE="integracion"; break;;
    *) echo "Selecciona 1 o 2";;
  esac
done

read -rp "Ruta base del endpoint (default: /api/history): " API_BASE
API_BASE=${API_BASE:-/api/history}

read -rp "Puerto del servidor (default: 3000): " PORT
PORT=${PORT:-3000}

read -rp "Ruta del archivo SQLite (default: ./data/history.db): " SQLITE_PATH
SQLITE_PATH=${SQLITE_PATH:-./data/history.db}

read -rp "¿Quieres habilitar Redis para cacheo rápido? (s/n, default: n): " USE_REDIS
USE_REDIS=${USE_REDIS:-n}

SERVER_ENTRY=""
if [[ "$MODE" == "integracion" ]]; then
  read -rp "Ruta del entry de tu servidor Express (ej: src/app.js o src/server.js): " SERVER_ENTRY
  if [[ -z "${SERVER_ENTRY}" ]]; then
    echo "⚠️ No indicaste entry. Igual crearé módulos y te mostraré el snippet para pegar."
  fi
fi

read -rp "¿Quieres generar un seed de datos de ejemplo? (s/n, default: s): " DO_SEED
DO_SEED=${DO_SEED:-s}

echo ""
echo "Resumen de configuración:"
echo "  - Modo: $MODE"
echo "  - API Base: $API_BASE"
echo "  - Puerto: $PORT"
echo "  - SQLite: $SQLITE_PATH"
echo "  - Redis: $USE_REDIS"
[[ "$MODE" == "integracion" ]] && echo "  - Entry server: ${SERVER_ENTRY:-(no especificado)}"
echo ""

read -rp "¿Continuar? (s/n): " OK
[[ "${OK,,}" == "s" ]] || { echo "Cancelado."; exit 0; }

# ===== instalar dependencias =====
BASE_DEPS=(express cors dotenv sqlite3 compression helmet morgan)
install_deps "$PKG_MANAGER" "${BASE_DEPS[@]}"

if [[ "${USE_REDIS,,}" == "s" ]]; then
  install_deps "$PKG_MANAGER" ioredis
fi

# ===== estructura carpetas =====
ensure_dir "src/config"
ensure_dir "src/utils"
ensure_dir "src/services/storage"
ensure_dir "src/services"
ensure_dir "src/controllers"
ensure_dir "src/routes"
ensure_dir "data"
ensure_dir "scripts"

# ===== archivos =====

# src/utils/validate.js
backup_if_exists "src/utils/validate.js"
cat > "src/utils/validate.js" <<'EOF'
function ensureEnv(key, fallback = undefined) {
  return process.env[key] ?? fallback;
}

function assertQuery(params) {
  const errors = [];
  const { monitorId, from, to, limit, offset, bucketMs } = params;

  if (!monitorId || typeof monitorId !== 'string') errors.push('monitorId requerido');
  if (!from || isNaN(Number(from))) errors.push('from inválido (epoch ms)');
  if (!to || isNaN(Number(to))) errors.push('to inválido (epoch ms)');

  if (limit !== undefined && (isNaN(Number(limit)) || Number(limit) < 1 || Number(limit) > 10000)) {
    errors.push('limit debe ser 1..10000');
  }
  if (offset !== undefined && (isNaN(Number(offset)) || Number(offset) < 0)) {
    errors.push('offset debe ser >= 0');
  }
  if (bucketMs !== undefined && (isNaN(Number(bucketMs)) || Number(bucketMs) < 1000)) {
    errors.push('bucketMs debe ser >= 1000');
  }

  return errors;
}

module.exports = { ensureEnv, assertQuery };
EOF
echo "✅ Escrito: src/utils/validate.js"

# src/services/storage/sqlite.js
backup_if_exists "src/services/storage/sqlite.js"
cat > "src/services/storage/sqlite.js" <<'EOF'
const path = require('path');
const sqlite3 = require('sqlite3').verbose();
const { ensureEnv } = require('../../utils/validate');

const dbFile = ensureEnv('SQLITE_PATH', './data/history.db');
const absolutePath = path.resolve(dbFile);

let db;

function initSQLite() {
  if (db) return db;

  db = new sqlite3.Database(absolutePath, (err) => {
    if (err) {
      console.error('SQLite connection error:', err);
      process.exit(1);
    }
  });

  db.serialize(() => {
    db.run(`
      CREATE TABLE IF NOT EXISTS monitor_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        monitorId TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        status TEXT NOT NULL,
        responseTime INTEGER,
        message TEXT
      );
    `);

    db.run(`CREATE INDEX IF NOT EXISTS idx_history_monitor_time ON monitor_history (monitorId, timestamp);`);
  });

  return db;
}

function insertHistory(event) {
  return new Promise((resolve, reject) => {
    const { monitorId, timestamp, status, responseTime = null, message = null } = event;
    db.run(
      `INSERT INTO monitor_history (monitorId, timestamp, status, responseTime, message)
       VALUES (?, ?, ?, ?, ?)`,
      [monitorId, timestamp, status, responseTime, message],
      function (err) {
        if (err) return reject(err);
        resolve({ id: this.lastID });
      }
    );
  });
}

function getHistory({ monitorId, from, to, limit = 1000, offset = 0 }) {
  return new Promise((resolve, reject) => {
    const params = [monitorId, from, to, limit, offset];
    db.all(
      `SELECT monitorId, timestamp, status, responseTime, message
       FROM monitor_history
       WHERE monitorId = ?
         AND timestamp >= ?
         AND timestamp <= ?
       ORDER BY timestamp ASC
       LIMIT ? OFFSET ?`,
      params,
      (err, rows) => {
        if (err) return reject(err);
        resolve(rows || []);
      }
    );
  });
}

function getHistoryAgg({ monitorId, from, to, bucketMs = 60000 }) {
  return new Promise((resolve, reject) => {
    const params = [monitorId, from, to];
    db.all(
      `SELECT monitorId, timestamp, status, responseTime
       FROM monitor_history
       WHERE monitorId = ?
         AND timestamp >= ?
         AND timestamp <= ?
       ORDER BY timestamp ASC`,
      params,
      (err, rows) => {
        if (err) return reject(err);
        const buckets = new Map();
        for (const r of rows) {
          const bucket = Math.floor(r.timestamp / bucketMs) * bucketMs;
          let b = buckets.get(bucket);
          if (!b) {
            b = { timestamp: bucket, up: 0, down: 0, degraded: 0, count: 0, p50: null, p95: null, rts: [] };
            buckets.set(bucket, b);
          }
          b.count++;
          if (r.status === 'up') b.up++;
          else if (r.status === 'down') b.down++;
          else b.degraded++;

          if (typeof r.responseTime === 'number') {
            b.rts.push(r.responseTime);
          }
        }
        const series = [];
        for (const [, b] of [...buckets.entries()].sort((a, b) => a[0] - b[0])) {
          b.rts.sort((a, b) => a - b);
          const p50Idx = Math.floor(0.5 * (b.rts.length - 1));
          const p95Idx = Math.floor(0.95 * (b.rts.length - 1));
          b.p50 = b.rts.length ? b.rts[p50Idx] : null;
          b.p95 = b.rts.length ? b.rts[p95Idx] : null;
          delete b.rts;
          series.push(b);
        }
        resolve(series);
      }
    );
  });
}

module.exports = {
  initSQLite,
  insertHistory,
  getHistory,
  getHistoryAgg,
};
EOF
echo "✅ Escrito: src/services/storage/sqlite.js"

# src/services/storage/redis.js (opcional)
if [[ "${USE_REDIS,,}" == "s" ]]; then
  backup_if_exists "src/services/storage/redis.js"
  cat > "src/services/storage/redis.js" <<'EOF'
const Redis = require('ioredis');
const { ensureEnv } = require('../../utils/validate');

let redis;
function initRedis() {
  if (redis) return redis;
  const url = ensureEnv('REDIS_URL', 'redis://localhost:6379');
  redis = new Redis(url);
  redis.on('error', (e) => console.error('Redis error:', e));
  return redis;
}

async function cacheRecentEvent(event, maxPerMonitor = 5000) {
  const r = initRedis();
  const key = `history:${event.monitorId}`;
  const payload = JSON.stringify(event);
  await r.lpush(key, payload);
  await r.ltrim(key, 0, maxPerMonitor - 1);
}

async function getRecentFromCache(monitorId, from, to) {
  const r = initRedis();
  const key = `history:${monitorId}`;
  const list = await r.lrange(key, 0, -1);
  const events = [];
  for (const item of list) {
    try {
      const e = JSON.parse(item);
      if (e.timestamp >= from && e.timestamp <= to) events.push(e);
    } catch {}
  }
  return events.sort((a, b) => a.timestamp - b.timestamp);
}

module.exports = { initRedis, cacheRecentEvent, getRecentFromCache };
EOF
  echo "✅ Escrito: src/services/storage/redis.js"
fi

# src/services/historyService.js
backup_if_exists "src/services/historyService.js"
cat > "src/services/historyService.js" <<'EOF'
const sqlite = require('./storage/sqlite');
// const redis = require('./storage/redis'); // Si quieres cache híbrido

function init() {
  sqlite.initSQLite();
}

async function addEvent(event) {
  return sqlite.insertHistory(event);
}

async function listRaw(params) {
  // Aquí podrías consultar Redis primero y completar con SQLite
  return sqlite.getHistory(params);
}

async function listSeries(params) {
  const bucketMs = Number(params.bucketMs || 60000);
  return sqlite.getHistoryAgg({ ...params, bucketMs });
}

module.exports = { init, addEvent, listRaw, listSeries };
EOF
echo "✅ Escrito: src/services/historyService.js"

# src/controllers/historyController.js
backup_if_exists "src/controllers/historyController.js"
cat > "src/controllers/historyController.js" <<'EOF'
const { assertQuery } = require('../utils/validate');
const historyService = require('../services/historyService');

async function getHistory(req, res) {
  try {
    const { monitorId, from, to } = req.query;
    const limit = Number(req.query.limit || 1000);
    const offset = Number(req.query.offset || 0);

    const errors = assertQuery({ monitorId, from, to, limit, offset });
    if (errors.length) return res.status(400).json({ errors });

    const rows = await historyService.listRaw({
      monitorId,
      from: Number(from),
      to: Number(to),
      limit,
      offset,
    });

    res.json({ data: rows, page: { limit, offset, count: rows.length } });
  } catch (err) {
    console.error('getHistory error:', err);
    res.status(500).json({ error: 'Internal Server Error' });
  }
}

async function getSeries(req, res) {
  try {
    const { monitorId, from, to } = req.query;
    const bucketMs = Number(req.query.bucketMs || 60000);

    const errors = assertQuery({ monitorId, from, to, bucketMs });
    if (errors.length) return res.status(400).json({ errors });

    const series = await historyService.listSeries({
      monitorId,
      from: Number(from),
      to: Number(to),
      bucketMs,
    });

    res.json({ data: series, meta: { bucketMs } });
  } catch (err) {
    console.error('getSeries error:', err);
    res.status(500).json({ error: 'Internal Server Error' });
  }
}

module.exports = { getHistory, getSeries };
EOF
echo "✅ Escrito: src/controllers/historyController.js"

# src/routes/historyRoutes.js
backup_if_exists "src/routes/historyRoutes.js"
cat > "src/routes/historyRoutes.js" <<'EOF'
const express = require('express');
const router = express.Router();
const ctrl = require('../controllers/historyController');

router.get('/', ctrl.getHistory);
router.get('/series', ctrl.getSeries);

module.exports = router;
EOF
echo "✅ Escrito: src/routes/historyRoutes.js"

# src/config/env.js
backup_if_exists "src/config/env.js"
cat > "src/config/env.js" <<'EOF'
require('dotenv').config();
module.exports = {
  port: Number(process.env.PORT || 3000),
  env: process.env.NODE_ENV || 'development',
};
EOF
echo "✅ Escrito: src/config/env.js"

# src/server.js (solo modo standalone)
if [[ "$MODE" == "standalone" ]]; then
  backup_if_exists "src/server.js"
  cat > "src/server.js" <<EOF
const express = require('express');
const cors = require('cors');
const compression = require('compression');
const helmet = require('helmet');
const morgan = require('morgan');

const { port, env } = require('./config/env');
const historyRoutes = require('./routes/historyRoutes');
const historyService = require('./services/historyService');

const app = express();

app.use(express.json({ limit: '1mb' }));
app.use(cors());
app.use(compression());
app.use(helmet());
app.use(morgan(env === 'development' ? 'dev' : 'combined'));

historyService.init();

app.use('${API_BASE}', historyRoutes);

app.get('/health', (_req, res) => res.json({ ok: true }));

app.listen(${PORT}, () => {
  console.log(\`[server] Listening on http://localhost:${PORT}\`);
});
EOF
  echo "✅ Escrito: src/server.js"
fi

# .env
backup_if_exists ".env"
cat > ".env" <<EOF
PORT=${PORT}
NODE_ENV=development
SQLITE_PATH=${SQLITE_PATH}
# REDIS_URL=redis://localhost:6379
EOF
echo "✅ Escrito: .env"

# seed (opcional)
if [[ "${DO_SEED,,}" == "s" ]]; then
  backup_if_exists "scripts/seed.js"
  cat > "scripts/seed.js" <<'EOF'
const { initSQLite, insertHistory } = require('../src/services/storage/sqlite');
initSQLite();

(async () => {
  const now = Date.now();
  const monitorId = 'api-main';
  for (let i = 0; i < 200; i++) {
    const t = now - i * 30000;
    const status = Math.random() < 0.9 ? 'up' : 'down';
    const responseTime = Math.floor(100 + Math.random() * 200);
    await insertHistory({ monitorId, timestamp: t, status, responseTime, message: null });
  }
  console.log('Seed done');
  process.exit(0);
})();
EOF
  echo "✅ Escrito: scripts/seed.js"
fi

# .gitignore
append_gitignore "/data/*.db"

# npm scripts (si es npm y modo standalone)
if [[ "$PKG_MANAGER" == "npm" && "$MODE" == "standalone" ]]; then
  npm_set_script "start" "node src/server.js" || true
fi

echo ""
echo "🎉 Listo."

if [[ "$MODE" == "standalone" ]]; then
  cat <<'EOT'

▶️ Para iniciar el servidor:
  - Si usas npm:   npm start
  - Yarn:          node src/server.js
  - PNPM:          node src/server.js

(Primero puedes sembrar datos si creaste el seed)
  node scripts/seed.js

🔍 Probar:
  FROM=$(( $(date +%s%3N) - 3600000 ))
  TO=$(date +%s%3N)
  curl "http://localhost:3000/api/history?monitorId=api-main&from=$FROM&to=$TO&limit=10&offset=0"
  curl "http://localhost:3000/api/history/series?monitorId=api-main&from=$FROM&to=$TO&bucketMs=60000"

EOT
else
  echo ""
  echo "📌 MODO INTEGRACIÓN: Agrega estas líneas en tu servidor Express:"
  echo "----------------------------------------------------------------"
  echo "En tu entry (ej: ${SERVER_ENTRY:-src/server.js}):"
  cat <<EOT
// 1) Requiere módulos
const historyRoutes = require('./src/routes/historyRoutes');
const historyService = require('./src/services/historyService');

// 2) Inicializa storage (una sola vez)
historyService.init();

// 3) Monta las rutas (usa tu base definida: ${API_BASE})
app.use('${API_BASE}', historyRoutes);
EOT
  echo "----------------------------------------------------------------"
  echo ""
  echo "Luego inicia tu servidor como siempre."
  echo "Usa .env para PORT y SQLITE_PATH. Seed opcional: node scripts/seed.js"
fi

echo ""
echo "✅ Recuerda actualizar tu frontend para usar el backend:"
cat <<'EOT'
/* historyEngine.js */
const API_BASE = process.env.HISTORY_API_BASE || 'http://localhost:3000';

export async function getSeriesForMonitor(monitorId, from, to, bucketMs = 60000) {
  const url = new URL('/api/history/series', API_BASE);
  url.searchParams.set('monitorId', monitorId);
  url.searchParams.set('from', String(from));
  url.searchParams.set('to', String(to));
  url.searchParams.set('bucketMs', String(bucketMs));
  const res = await fetch(url.toString());
  if (!res.ok) throw new Error('History API error');
  const json = await res.json();
  return json.data;
}
EOT

echo ""
echo "Si quieres, te lo dejo en TypeScript o con Redis híbrido. ¡Dímelo y te lo genero!"

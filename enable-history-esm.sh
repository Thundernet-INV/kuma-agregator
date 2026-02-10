#!/usr/bin/env bash
set -euo pipefail

# ===========================================
# Configuración
# ===========================================
ROOT_DIR="$(pwd)"
INDEX_JS="src/index.js"
UTILS_VALIDATE="src/utils/validate.js"
SQLITE_JS="src/services/storage/sqlite.js"
SERVICE_JS="src/services/historyService.js"
CTRL_JS="src/controllers/historyController.js"
ROUTES_JS="src/routes/historyRoutes.js"
DATA_DIR="data"
ENABLE_POST=0

# Args
if [[ "${1:-}" == "--enable-post" ]]; then
  ENABLE_POST=1
fi

ts() { date +%Y%m%d-%H%M%S; }
backup() {
  local f="$1"
  if [[ -f "$f" ]]; then
    local b="${f}.bak-$(ts)"
    cp "$f" "$b"
    echo "  - Backup: $f -> $b"
  fi
}
ensure_dir() {
  local d="$1"
  [[ -d "$d" ]] || { mkdir -p "$d"; echo "  - Creado dir: $d"; }
}

echo "🔎 Verificando raíz del backend..."
if [[ ! -f "package.json" ]]; then
  echo "❌ No encuentro package.json en $ROOT_DIR"
  echo "Ubícate en la raíz del backend (ej: /opt/kuma-central/kuma-aggregator) y reintenta."
  exit 1
fi
if [[ ! -f "$INDEX_JS" ]]; then
  echo "❌ No existe $INDEX_JS. Verifica la ruta del entry."
  exit 1
fi

echo "🧭 Backend: $ROOT_DIR"
echo "📄 Entry:   $INDEX_JS"

# ===========================================
# Asegurar ESM en package.json ("type":"module")
# ===========================================
if ! grep -q '"type"[[:space:]]*:[[:space:]]*"module"' package.json; then
  echo "🛠  Activando ESM en package.json (type: module)"
  backup "package.json"
  node - <<'NODE'
const fs = require('fs');
const p = 'package.json';
const raw = fs.readFileSync(p,'utf8');
const pkg = JSON.parse(raw);
if (!pkg.type) pkg.type = 'module';
else pkg.type = 'module';
fs.writeFileSync(p, JSON.stringify(pkg, null, 2));
console.log('  - package.json actualizado con "type":"module"');
NODE
fi

# ===========================================
# Escribir archivos ESM (idempotente con backup)
# ===========================================
echo "✍️   Escribiendo módulos ESM..."

# utils/validate.js
backup "$UTILS_VALIDATE"
cat > "$UTILS_VALIDATE" <<'EOF'
export function ensureEnv(key, fallback = undefined) {
  return process.env[key] ?? fallback;
}

export function assertQuery(params) {
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
EOF

# services/storage/sqlite.js
ensure_dir "src/services/storage"
backup "$SQLITE_JS"
cat > "$SQLITE_JS" <<'EOF'
import path from 'path';
import sqlite3pkg from 'sqlite3';
import { ensureEnv } from '../../utils/validate.js';

const sqlite3 = sqlite3pkg.verbose();
const dbFile = ensureEnv('SQLITE_PATH', './data/history.db');
const absolutePath = path.resolve(dbFile);

let db;

export function initSQLite() {
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

    db.run(\`CREATE INDEX IF NOT EXISTS idx_history_monitor_time ON monitor_history (monitorId, timestamp);\`);
  });

  return db;
}

export function insertHistory(event) {
  return new Promise((resolve, reject) => {
    const { monitorId, timestamp, status, responseTime = null, message = null } = event;
    db.run(
      \`INSERT INTO monitor_history (monitorId, timestamp, status, responseTime, message)
       VALUES (?, ?, ?, ?, ?)\`,
      [monitorId, timestamp, status, responseTime, message],
      function (err) {
        if (err) return reject(err);
        resolve({ id: this.lastID });
      }
    );
  });
}

export function getHistory({ monitorId, from, to, limit = 1000, offset = 0 }) {
  return new Promise((resolve, reject) => {
    const params = [monitorId, from, to, limit, offset];
    db.all(
      \`SELECT monitorId, timestamp, status, responseTime, message
       FROM monitor_history
       WHERE monitorId = ?
         AND timestamp >= ?
         AND timestamp <= ?
       ORDER BY timestamp ASC
       LIMIT ? OFFSET ?\`,
      params,
      (err, rows) => {
        if (err) return reject(err);
        resolve(rows || []);
      }
    );
  });
}

export function getHistoryAgg({ monitorId, from, to, bucketMs = 60000 }) {
  return new Promise((resolve, reject) => {
    const params = [monitorId, from, to];
    db.all(
      \`SELECT monitorId, timestamp, status, responseTime
       FROM monitor_history
       WHERE monitorId = ?
         AND timestamp >= ?
         AND timestamp <= ?
       ORDER BY timestamp ASC\`,
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
EOF

# services/historyService.js
ensure_dir "src/services"
backup "$SERVICE_JS"
cat > "$SERVICE_JS" <<'EOF'
import { initSQLite, insertHistory, getHistory, getHistoryAgg } from './storage/sqlite.js';

export function init() {
  initSQLite();
}

export async function addEvent(event) {
  return insertHistory(event);
}

export async function listRaw(params) {
  return getHistory(params);
}

export async function listSeries(params) {
  const bucketMs = Number(params.bucketMs || 60000);
  return getHistoryAgg({ ...params, bucketMs });
}
EOF

# controllers/historyController.js
ensure_dir "src/controllers"
backup "$CTRL_JS"
cat > "$CTRL_JS" <<'EOF'
import { assertQuery } from '../utils/validate.js';
import * as historyService from '../services/historyService.js';

export async function getHistory(req, res) {
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

export async function getSeries(req, res) {
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

export async function postEvent(req, res) {
  try {
    const { monitorId, timestamp, status, responseTime = null, message = null } = req.body || {};
    const errors = [];
    if (!monitorId) errors.push('monitorId requerido');
    if (!timestamp || isNaN(Number(timestamp))) errors.push('timestamp inválido (epoch ms)');
    if (!['up', 'down', 'degraded'].includes(status)) errors.push("status debe ser 'up' | 'down' | 'degraded'");
    if (errors.length) return res.status(400).json({ errors });

    const result = await historyService.addEvent({ monitorId, timestamp: Number(timestamp), status, responseTime, message });
    res.status(201).json({ ok: true, id: result.id });
  } catch (e) {
    console.error('postEvent error:', e);
    res.status(500).json({ error: 'Internal Server Error' });
  }
}
EOF

# routes/historyRoutes.js
ensure_dir "src/routes"
backup "$ROUTES_JS"
if [[ $ENABLE_POST -eq 1 ]]; then
cat > "$ROUTES_JS" <<'EOF'
import { Router } from 'express';
import { getHistory, getSeries, postEvent } from '../controllers/historyController.js';

const router = Router();

router.get('/', getHistory);
router.get('/series', getSeries);
router.post('/', postEvent);

export default router;
EOF
else
cat > "$ROUTES_JS" <<'EOF'
import { Router } from 'express';
import { getHistory, getSeries } from '../controllers/historyController.js';

const router = Router();

router.get('/', getHistory);
router.get('/series', getSeries);
// router.post('/', postEvent); // habilita con --enable-post

export default router;
EOF
fi

echo "✅ Archivos ESM escritos."

# ===========================================
# Parchar src/index.js
# ===========================================
echo "🧩 Parchando $INDEX_JS"

# Flags para no duplicar
has_import_routes=0
has_import_service=0
has_init=0
has_mount=0

grep -q "./routes/historyRoutes.js" "$INDEX_JS" && has_import_routes=1 || true
grep -q "./services/historyService.js" "$INDEX_JS" && has_import_service=1 || true
grep -q "historyService\.init" "$INDEX_JS" && has_init=1 || true
grep -q "app\.use('/api/history', historyRoutes)" "$INDEX_JS" && has_mount=1 || true

# 1) Insertar imports después del último import
if [[ $has_import_routes -eq 0 || $has_import_service -eq 0 ]]; then
  backup "$INDEX_JS"
  awk -v add_routes=$((1-has_import_routes)) -v add_service=$((1-has_import_service)) '
    BEGIN{li=0}
    /^import /{li=NR}
    {lines[NR]=$0}
    END{
      for(i=1;i<=NR;i++){
        print lines[i]
        if(i==li){
          if(add_routes)  print "import historyRoutes from \x27./routes/historyRoutes.js\x27;"
          if(add_service) print "import * as historyService from \x27./services/historyService.js\x27;"
        }
      }
    }
  ' "$INDEX_JS" > "${INDEX_JS}.new"
  mv "${INDEX_JS}.new" "$INDEX_JS"
  echo "  - Imports añadidos"
fi

# 2) Insertar historyService.init() después de app.use(express.json...) o después de const app = express()
if [[ $has_init -eq 0 ]]; then
  backup "$INDEX_JS"
  target_line=$(grep -nE 'app\.use\(.+express\.json' "$INDEX_JS" | head -n1 | cut -d: -f1 || true)
  if [[ -z "${target_line}" ]]; then
    target_line=$(grep -nE 'const[[:space:]]+app[[:space:]]*=[[:space:]]*express\(\)' "$INDEX_JS" | head -n1 | cut -d: -f1 || true)
  fi
  if [[ -z "${target_line}" ]]; then
    echo "  ! No pude localizar dónde insertar historyService.init(). Inserta manualmente cerca del setup de middlewares."
  else
    awk -v tline="$target_line" '
      { print $0; if(NR==tline) print "historyService.init();"}
    ' "$INDEX_JS" > "${INDEX_JS}.new"
    mv "${INDEX_JS}.new" "$INDEX_JS"
    echo "  - historyService.init() insertado"
  fi
fi

# 3) Montar rutas app.use('/api/history', historyRoutes)
if [[ $has_mount -eq 0 ]]; then
  backup "$INDEX_JS"
  # Intentar montarlo después de historyService.init(); si no, después de app.use(express.json...); si no, después de const app=express();
  target_line=$(grep -n "historyService\.init" "$INDEX_JS" | head -n1 | cut -d: -f1 || true)
  if [[ -z "${target_line}" ]]; then
    target_line=$(grep -nE 'app\.use\(.+express\.json' "$INDEX_JS" | head -n1 | cut -d: -f1 || true)
  fi
  if [[ -z "${target_line}" ]]; then
    target_line=$(grep -nE 'const[[:space:]]+app[[:space:]]*=[[:space:]]*express\(\)' "$INDEX_JS" | head -n1 | cut -d: -f1 || true)
  fi
  if [[ -z "${target_line}" ]]; then
    echo "  ! No pude localizar dónde montar rutas. Inserta manual: app.use('/api/history', historyRoutes)"
  else
    awk -v tline="$target_line" '
      { print $0; if(NR==tline) print "app.use(\x27/api/history\x27, historyRoutes);"}
    ' "$INDEX_JS" > "${INDEX_JS}.new"
    mv "${INDEX_JS}.new" "$INDEX_JS"
    echo "  - Rutas montadas: /api/history"
  fi
fi

# ===========================================
# Data dir y permisos
# ===========================================
echo "📂 Asegurando carpeta de base de datos..."
ensure_dir "$DATA_DIR"
chmod 775 "$DATA_DIR" || true
echo "  - $DATA_DIR listo"

# ===========================================
# Mensaje final
# ===========================================
echo ""
echo "🎉 Hecho."
echo "Ahora reinicia tu backend y prueba:"
cat <<'EOC'
FROM=$(( $(date +%s%3N) - 3600000 ))
TO=$(date +%s%3N)

# Eventos crudos:
curl "http://localhost:8080/api/history?monitorId=api-main&from=$FROM&to=$TO&limit=10&offset=0"

# Series agregadas (bucket 60s):
curl "http://localhost:8080/api/history/series?monitorId=api-main&from=$FROM&to=$TO&bucketMs=60000"

# Si ejecutaste con --enable-post, puedes insertar un evento:
# curl -X POST "http://localhost:8080/api/history" \
#   -H "Content-Type: application/json" \
#   -d '{"monitorId":"api-main","timestamp":'$(date +%s%3N)',"status":"up","responseTime":183,"message":"OK"}'
EOC


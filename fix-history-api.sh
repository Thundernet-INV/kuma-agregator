#!/usr/bin/env bash
set -euo pipefail

# Config
ROOT="/opt/kuma-central/kuma-aggregator"
INDEX="$ROOT/src/index.js"
ROUTES="$ROOT/src/routes/historyRoutes.js"
CTRL="$ROOT/src/controllers/historyController.js"
SERVICE="kuma-aggregator.service"

ts() { date +%Y%m%d-%H%M%S; }
backup() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local b="${f}.bak-$(ts)"
  cp "$f" "$b"
  echo "  - Backup: $f -> $b"
}

echo "🔎 Verificando paths..."
[[ -f "$INDEX" ]] || { echo "❌ No existe $INDEX"; exit 1; }
[[ -f "$ROUTES" ]] || { echo "❌ No existe $ROUTES"; exit 1; }
[[ -f "$CTRL" ]] || { echo "❌ No existe $CTRL"; exit 1; }

echo "🧩 Asegurando que el router tenga postEvent importado y montado..."
# Forzar que historyRoutes.js importe postEvent y monte POST
if ! grep -q "postEvent" "$ROUTES"; then
  backup "$ROUTES"
  # Sobrescribe con versión correcta (ESM)
  cat > "$ROUTES" <<'EOF'
import { Router } from 'express';
import { getHistory, getSeries, postEvent } from '../controllers/historyController.js';

const router = Router();

router.get('/', getHistory);
router.get('/series', getSeries);
router.post('/', postEvent); // habilitado

export default router;
EOF
  echo "  - Reescrito $ROUTES con POST habilitado."
else
  # Asegurar que esté la línea del POST
  if ! grep -q "router.post('/'," "$ROUTES"; then
    backup "$ROUTES"
    awk '
      BEGIN{added=0}
      {print}
      /router.get\(.*series/ && !added {print "router.post('\''/'\'', postEvent);"; added=1}
    ' "$ROUTES" > "$ROUTES.tmp" && mv "$ROUTES.tmp" "$ROUTES"
    echo "  - Añadido router.post('/', postEvent) en $ROUTES"
  fi
fi

echo "🧩 Verificando que historyController.js exporte postEvent..."
if ! grep -q "export async function postEvent" "$CTRL"; then
  backup "$CTRL"
  # Leemos el archivo actual y si no está postEvent, lo añadimos al final manteniendo ESM
  cat >> "$CTRL" <<'EOF'

export async function postEvent(req, res) {
  try {
    const { monitorId, timestamp, status, responseTime = null, message = null } = req.body || {};
    const errors = [];
    if (!monitorId) errors.push('monitorId requerido');
    if (!timestamp || isNaN(Number(timestamp))) errors.push('timestamp inválido (epoch ms)');
    if (!['up', 'down', 'degraded'].includes(status)) errors.push("status debe ser 'up' | 'down' | 'degraded'");
    if (errors.length) return res.status(400).json({ errors });

    const { addEvent } = await import('../services/historyService.js');
    const result = await addEvent({
      monitorId,
      timestamp: Number(timestamp),
      status,
      responseTime,
      message
    });

    res.status(201).json({ ok: true, id: result.id });
  } catch (e) {
    console.error('postEvent error:', e);
    res.status(500).json({ error: 'Internal Server Error' });
  }
}
EOF
  echo "  - Añadido export postEvent en $CTRL"
fi

echo "🧩 Forzando que el router se monte con su propio express.json() en index.js..."
backup "$INDEX"

# 1) Asegurar import de historyRoutes y historyService (si no existen)
if ! grep -q "from './routes/historyRoutes.js'" "$INDEX"; then
  awk '
    BEGIN{li=0}
    /^import /{li=NR}
    {lines[NR]=$0}
    END{
      for(i=1;i<=NR;i++){
        print lines[i]
        if(i==li){
          print "import historyRoutes from \x27./routes/historyRoutes.js\x27;"
          print "import * as historyService from \x27./services/historyService.js\x27;"
        }
      }
    }
  ' "$INDEX" > "$INDEX.tmp" && mv "$INDEX.tmp" "$INDEX"
  echo "  - Añadidos imports de historyRoutes y historyService en $INDEX"
fi

# 2) Asegurar historyService.init() después de app.use(express.json(...)) o const app=express()
if ! grep -q "historyService.init()" "$INDEX"; then
  target=$(grep -nE 'app\.use\(.+express\.json' "$INDEX" | head -n1 | cut -d: -f1 || true)
  if [[ -z "$target" ]]; then
    target=$(grep -nE 'const[[:space:]]+app[[:space:]]*=[[:space:]]*express\(' "$INDEX" | head -n1 | cut -d: -f1 || true)
  fi
  if [[ -n "$target" ]]; then
    awk -v t="$target" '{print} NR==t{print "historyService.init();"}' "$INDEX" > "$INDEX.tmp" && mv "$INDEX.tmp" "$INDEX"
    echo "  - Insertado historyService.init() en $INDEX"
  else
    echo "  ! No se encontró lugar claro para init(); por favor verifica manualmente."
  fi
fi

# 3) Asegurar montaje con parser local
if grep -q "app.use('/api/history', historyRoutes)" "$INDEX"; then
  # Reemplazar por versión con parser local
  sed -i "s|app.use('/api/history', historyRoutes);|app.use('/api/history', express.json({ limit: '256kb' }), historyRoutes);|" "$INDEX" || true
elif ! grep -q "express.json({ limit: '256kb' }), historyRoutes" "$INDEX"; then
  # Insertar después de historyService.init() o del parser global
  t=$(grep -n "historyService\.init()" "$INDEX" | head -n1 | cut -d: -f1 || true)
  if [[ -z "$t" ]]; then
    t=$(grep -nE 'app\.use\(.+express\.json' "$INDEX" | head -n1 | cut -d: -f1 || true)
  fi
  if [[ -n "$t" ]]; then
    awk -v t="$t" '{print} NR==t{print "app.use(\x27/api/history\x27, express.json({ limit: \x27256kb\x27 }), historyRoutes);"}' "$INDEX" > "$INDEX.tmp" && mv "$INDEX.tmp" "$INDEX"
    echo "  - Montado router con parser local en $INDEX"
  else
    echo "  ! No se pudo insertar el montaje del router automáticamente. Revisa $INDEX."
  fi
fi

echo "🔄 Reiniciando servicio systemd: $SERVICE"
sudo systemctl daemon-reload
sudo systemctl restart "$SERVICE"
sleep 1
sudo systemctl status "$SERVICE" --no-pager -l || true

echo "🧪 Probando POST y GET..."
TS_MS=$(( $(date +%s) * 1000 ))

# POST (here-doc, JSON válido)
POST_RESP=$(curl -s -X POST "http://localhost:8080/api/history" \
  -H "Content-Type: application/json" \
  --data-binary @- <<EOF
{"monitorId":"api-main","timestamp":$TS_MS,"status":"up","responseTime":183,"message":"OK"}
EOF
)
echo "POST -> $POST_RESP"

# GET última hora
FROM=$(( $(date +%s)*1000 - 3600000 ))
TO=$(( $(date +%s)*1000 ))

RAW=$(curl -sG "http://localhost:8080/api/history" \
  --data-urlencode "monitorId=api-main" \
  --data-urlencode "from=$FROM" \
  --data-urlencode "to=$TO" \
  --data-urlencode "limit=5" \
  --data-urlencode "offset=0")
SERIES=$(curl -sG "http://localhost:8080/api/history/series" \
  --data-urlencode "monitorId=api-main" \
  --data-urlencode "from=$FROM" \
  --data-urlencode "to=$TO" \
  --data-urlencode "bucketMs=60000")

echo "GET /api/history -> $RAW"
echo "GET /api/history/series -> $SERIES"

echo "✅ Listo. Si POST devolvió {\"ok\":true,...}, todo quedó funcionando."


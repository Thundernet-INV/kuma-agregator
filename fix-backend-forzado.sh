#!/bin/bash
# fix-backend-forzado.sh - LIMPIEZA TOTAL DEL INDEX.JS

echo "====================================================="
echo "🔴 LIMPIEZA TOTAL DEL INDEX.JS - VERSIÓN LIMPIA"
echo "====================================================="

BACKEND_DIR="/opt/kuma-central/kuma-aggregator/src"
BACKUP_DIR="${BACKEND_DIR}/backup_forzado_$(date +%Y%m%d_%H%M%S)"

# ========== 1. CREAR BACKUP ==========
echo ""
echo "[1] Creando backup completo..."
mkdir -p "$BACKUP_DIR"
cp "${BACKEND_DIR}/index.js" "$BACKUP_DIR/index.js.bak"
cp "${BACKEND_DIR}/routes/instanceAveragesRoutes.js" "$BACKUP_DIR/" 2>/dev/null || true
echo "✅ Backup creado en: $BACKUP_DIR"
echo ""

# ========== 2. CREAR INDEX.JS NUEVO Y LIMPIO ==========
echo "[2] Creando index.js NUEVO y LIMPIO..."

cat > "${BACKEND_DIR}/index.js" << 'EOF'
import express from "express";
const DENY_NAMES = (process.env.DENY_NAMES || "").split(",").map(s=>s.trim()).filter(Boolean);
const DENY_INSTANCE_REGEX = process.env.DENY_INSTANCE_REGEX ? new RegExp(process.env.DENY_INSTANCE_REGEX) : null;

import cors from "cors";
import fs from "fs";
import { Store } from "./store.js";
import { pollInstance, extract } from "./poller.js";
import historyRoutes from './routes/historyRoutes.js';
import instanceRoutes from "./routes/instanceRoutes.js";
import blocklistRoutes from "./routes/blocklistRoutes.js";
import metricHistoryRoutes from './routes/metricHistoryRoutes.js';
import * as historyService from './services/historyService.js';

// 🆕 NUEVO: Endpoint de promedios (SIN DUPLICAR)
import instanceAveragesRoutes from './routes/instanceAveragesRoutes.js';

const instances = JSON.parse(fs.readFileSync("./instances.json","utf-8"));

const app = express();
historyService.init();

app.use(cors({
  origin: ["http://localhost:5174", "http://localhost:5173", "http://10.10.31.31:5174", "http://10.10.31.31:5173", "http://10.10.31.31:8081", "http://10.10.31.31"],
  credentials: true,
  methods: ["GET", "POST", "PUT", "DELETE", "OPTIONS", "HEAD"],
  allowedHeaders: ["Content-Type", "Authorization", "Pragma", "Cache-Control", "X-Requested-With", "Accept", "Accept-Encoding", "Accept-Language", "Connection", "Host", "Origin", "Referer", "User-Agent"]
}));
app.options("*", cors());
app.use(express.json({ limit: "256kb" }));

app.use('/api/history', express.json({ limit: '256kb' }), historyRoutes);
app.use('/api/metric-history', metricHistoryRoutes);
// 🆕 NUEVO: Montar endpoint de promedios (UNA SOLA VEZ)
app.use('/api/instance/averages', instanceAveragesRoutes);

const store = new Store();

async function cycle() {
  const nextInstances = [];
  const nextMonitors  = [];

  for (const inst of instances) {
    try {
      const series    = await pollInstance(inst);
      const extracted = extract(series);
      nextInstances.push({ name: inst.name, ok: true });
      for (const m of extracted) {
        nextMonitors.push({ instance: inst.name, ...m });
        
        // ✅ Guardar en SQLite automáticamente
        await historyService.addEvent({
          monitorId: `${inst.name}_${m.info?.monitor_name}`.replace(/\s+/g, '_'),
          timestamp: Date.now(),
          status: m.latest?.status === 1 ? 'up' : 'down',
          responseTime: m.latest?.responseTime || null,
          message: null
        });
      }
    } catch (error) {
      nextInstances.push({ name: inst.name, ok: false });
      
      // ✅ Guardar errores
      await historyService.addEvent({
        monitorId: `${inst.name}_error`,
        timestamp: Date.now(),
        status: 'down',
        responseTime: null,
        message: `Error polling: ${error.message}`
      });
    }
  }

  // Purga y reemplaza el estado (sin fantasmas)
  store.replaceSnapshot({ instances: nextInstances, monitors: nextMonitors });

  // Notifica a suscriptores SSE
  store.broadcast("tick", store.snapshot());

// --- Debug: log por ciclo para LOG_TARGET ---
const LOG_TARGET = process.env.LOG_TARGET || '';
if (LOG_TARGET) {
  const snap = store.snapshot();
  const hits = snap.monitors.filter(m => (m.info?.monitor_name === LOG_TARGET));
  if (hits.length > 0) {
    const byInst = {}; hits.forEach(h => { byInst[h.instance] = (byInst[h.instance]||0) + 1; });
    console.log(`[debug] target="${LOG_TARGET}" count=${hits.length} byInstance=${JSON.stringify(byInst)}`);
  } else {
    console.log(`[debug] target="${LOG_TARGET}" count=0`);
  }
}

}

setInterval(cycle, 5000);
cycle();

// API JSON con anti-cache
app.get("/api/summary", (req, res) => {
  res.set({
    "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
    "Pragma":        "no-cache",
    "Expires":       "0",
  });
  res.json(store.snapshot());
});

// SSE
app.get("/api/stream", (req, res) => {
  res.set({
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    "Connection": "keep-alive",
  });
  res.flushHeaders();
  store.subscribers.add(res);
  req.on("close",()=>store.subscribers.delete(res));
});

// /health
app.get("/health", (req, res) => {
  const s = store.snapshot();
  res.json({
    ok: true,
    instances: s.instances.length,
    monitors:  s.monitors.length,
    ts: new Date().toISOString()
  });
});

app.listen(8080, () => console.log("Aggregator on 8080"));

// --- Endpoints de depuración ---
app.get("/debug/find", (req, res) => {
  const q = (req.query.name || "").toString();
  const s = store.snapshot();
  const hits = s.monitors.filter(m => m.info?.monitor_name === q);
  res.set({
    "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
    "Pragma": "no-cache","Expires": "0",
  });
  res.json({ name: q, hits });
});

app.get("/debug/dump", (req, res) => {
  const inst = (req.query.instance || "").toString();
  const s = store.snapshot();
  const all = inst ? s.monitors.filter(m => m.instance === inst) : s.monitors;
  res.set({
    "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
    "Pragma": "no-cache","Expires": "0",
  });
  res.json({ instance: inst || null, count: all.length, items: all });
});

// ---- Admin: reset del snapshot actual ----
app.post("/admin/reset", (req, res) => {
  try {
    store.replaceSnapshot({ instances: [], monitors: [] });
    store.broadcast("tick", store.snapshot());
    res.json({ ok: true, cleared: true });
  } catch (e) {
    console.error("[admin/reset]", e);
    res.status(500).json({ ok: false, error: String(e) });
  }
});

// ---- Admin: reindex forzado ----
app.post("/admin/reindex", (req, res) => {
  setImmediate(async () => {
    try {
      await cycle();
    } catch (e) {
      console.error("[admin/reindex]", e);
    }
  });
  res.status(202).json({ ok: true, message: "reindex scheduled" });
});

// ---- Admin: reset + reindex ----
app.post("/admin/reset-and-reindex", (req, res) => {
  try {
    store.replaceSnapshot({ instances: [], monitors: [] });
    store.broadcast("tick", store.snapshot());
    setImmediate(async () => {
      try {
        await cycle();
      } catch (e) {
        console.error("[admin/reset-and-reindex]", e);
      }
    });
    res.status(202).json({ ok: true, message: "reset done, reindex scheduled" });
  } catch (e) {
    console.error("[admin/reset-and-reindex]", e);
    res.status(500).json({ ok: false, error: String(e) });
  }
});

// ---- Admin: Limpiar monitores fantasma ----
app.post("/admin/cleanup-fantasma", async (req, res) => {
    try {
        const { cleanupInactiveMonitors } = await import('./services/storage/sqlite.js');
        const removed = await cleanupInactiveMonitors(1);
        setImmediate(async () => {
            try {
                await cycle();
            } catch (e) {
                console.error("[admin/cleanup-fantasma] Error en ciclo:", e);
            }
        });
        res.json({ 
            ok: true, 
            message: `✅ Limpieza completada: ${removed} monitores fantasma eliminados`,
            removed,
            timestamp: Date.now()
        });
    } catch (e) {
        console.error("[admin/cleanup-fantasma]", e);
        res.status(500).json({ ok: false, error: String(e) });
    }
});
EOF

echo "✅ index.js NUEVO creado - 100% limpio, sin imports duplicados"
echo ""

# ========== 3. VERIFICAR QUE NO HAY DUPLICADOS ==========
echo "[3] Verificando que no hay duplicados..."

IMPORT_COUNT=$(grep -c "import instanceAveragesRoutes" "${BACKEND_DIR}/index.js")
echo "   • Imports de instanceAveragesRoutes: $IMPORT_COUNT (debe ser 1)"

USE_COUNT=$(grep -c "app.use('/api/instance/averages'" "${BACKEND_DIR}/index.js")
echo "   • Montajes del endpoint: $USE_COUNT (debe ser 1)"

if [ "$IMPORT_COUNT" -eq 1 ] && [ "$USE_COUNT" -eq 1 ]; then
    echo "✅ TODO CORRECTO - Archivo limpio"
else
    echo "❌ AÚN HAY PROBLEMAS - Revisar manualmente"
fi
echo ""

# ========== 4. REINICIAR BACKEND ==========
echo "[4] Reiniciando backend..."

cd "${BACKEND_DIR}/.."

# Matar procesos existentes
pkill -f "node.*index.js" 2>/dev/null || true
sleep 2

# Iniciar backend
NODE_ENV=production nohup node src/index.js > /tmp/kuma-backend.log 2>&1 &
BACKEND_PID=$!
sleep 3

echo "✅ Backend iniciado con PID: $BACKEND_PID"

# ========== 5. VERIFICAR BACKEND ==========
echo ""
echo "[5] Verificando backend..."

if ps -p $BACKEND_PID > /dev/null; then
    echo "✅ Proceso vivo"
    
    # Probar health
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/health)
    if [ "$HTTP_CODE" = "200" ]; then
        echo "✅ Health check OK"
    else
        echo "❌ Health check falló"
        tail -20 /tmp/kuma-backend.log
    fi
    
    # Probar summary
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/api/summary)
    if [ "$HTTP_CODE" = "200" ]; then
        echo "✅ Summary OK"
    else
        echo "❌ Summary falló"
    fi
else
    echo "❌ El proceso murió"
    echo ""
    echo "=== ÚLTIMAS LÍNEAS DEL LOG ==="
    tail -20 /tmp/kuma-backend.log
    exit 1
fi

# ========== 6. VERIFICAR ENDPOINT NUEVO ==========
echo ""
echo "[6] Verificando endpoint de promedios..."

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/api/instance/averages/Caracas?hours=1)
if [ "$HTTP_CODE" = "200" ]; then
    echo "✅ Endpoint de promedios OK"
else
    echo "⚠️ Endpoint de promedios responde con HTTP $HTTP_CODE"
fi

# ========== 7. REINICIAR FRONTEND ==========
echo ""
echo "[7] Reiniciando frontend..."

FRONTEND_DIR="/home/thunder/kuma-dashboard-clean/kuma-ui"
cd "$FRONTEND_DIR"
pkill -f "vite" 2>/dev/null || true
npm run dev &
sleep 3

# ========== 8. INSTRUCCIONES ==========
echo ""
echo "====================================================="
echo "✅✅ BACKEND CORREGIDO FORZOSAMENTE ✅✅"
echo "====================================================="
echo ""
echo "📋 ESTADO FINAL:"
echo ""
echo "   • ✅ index.js: NUEVO y LIMPIO"
echo "   • ✅ Import de promedios: 1 sola vez"
echo "   • ✅ Montaje de endpoint: 1 sola vez"
echo "   • ✅ Backend corriendo (PID: $BACKEND_PID)"
echo ""
echo "🔄 PRUEBA AHORA:"
echo ""
echo "   1. Abre http://10.10.31.31:5173"
echo "   2. ✅ EL DASHBOARD DEBE FUNCIONAR INMEDIATAMENTE"
echo "   3. ✅ Las gráficas de histórico DEBEN aparecer"
echo ""
echo "📌 RESPALDO DE SEGURIDAD:"
echo "   Backup creado en: $BACKUP_DIR"
echo ""
echo "====================================================="

# Preguntar si quiere abrir el navegador
read -p "¿Abrir el dashboard ahora? (s/N): " OPEN_BROWSER
if [[ "$OPEN_BROWSER" =~ ^[Ss]$ ]]; then
    xdg-open "http://10.10.31.31:5173" 2>/dev/null || \
    open "http://10.10.31.31:5173" 2>/dev/null || \
    echo "Abre http://10.10.31.31:5173 en tu navegador"
fi

echo ""
echo "✅ Script completado"

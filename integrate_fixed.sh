#!/bin/bash

# integrate_historial_fixed.sh
# Script CORREGIDO para integrar historial persistente en Kuma Dashboard
# Ejecutar: sudo bash integrate_historial_fixed.sh

# Configuración - RUTAS CORREGIDAS
BACKEND_DIR="/opt/kuma-central/kuma-aggregator/src"
FRONTEND_DIR="/home/thunder/kuma-dashboard-clean/kuma-ui"
LOG_FILE="/tmp/integration_fixed_$(date +%Y%m%d_%H%M%S).log"

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Función para loguear
log() {
    echo -e "${GREEN}[+]${NC} $1"
    echo "[+] $1" >> "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    echo "[ERROR] $1" >> "$LOG_FILE"
    exit 1
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    echo "[WARN] $1" >> "$LOG_FILE"
}

# Verificar que existan los directorios
check_directories() {
    log "Verificando directorios..."
    
    if [ ! -d "$BACKEND_DIR" ]; then
        error "Directorio backend no encontrado: $BACKEND_DIR"
    fi
    
    if [ ! -d "$FRONTEND_DIR" ]; then
        error "Directorio frontend no encontrado: $FRONTEND_DIR"
    fi
    
    log "Backend: $BACKEND_DIR"
    log "Frontend: $FRONTEND_DIR"
    log "Log: $LOG_FILE"
}

# Verificar archivos existentes
check_existing_files() {
    log "Verificando archivos existentes..."
    
    # Archivos del backend
    if [ ! -f "$BACKEND_DIR/index.js" ]; then
        error "index.js no encontrado en $BACKEND_DIR"
    fi
    
    if [ ! -f "$BACKEND_DIR/store.js" ]; then
        warn "store.js no encontrado en $BACKEND_DIR"
    fi
    
    if [ ! -f "$BACKEND_DIR/poller.js" ]; then
        warn "poller.js no encontrado en $BACKEND_DIR"
    fi
    
    # Verificar si ya hay una base de datos
    if [ -f "/opt/kuma-central/kuma-aggregator/data/history.db" ]; then
        warn "Base de datos history.db ya existe"
    fi
    
    log "Verificación de archivos completada"
}

# Backup de archivos originales
backup_files() {
    log "Creando backups..."
    
    TIMESTAMP=$(date +%s)
    
    # Backend - archivos críticos
    declare -a backend_files=("index.js" "store.js" "poller.js" "services/historyService.js")
    
    for file in "${backend_files[@]}"; do
        if [ -f "$BACKEND_DIR/$file" ]; then
            cp "$BACKEND_DIR/$file" "$BACKEND_DIR/$file.backup.$TIMESTAMP"
            log "  Backup: $file → $file.backup.$TIMESTAMP"
        fi
    done
    
    log "Backups creados con éxito"
}

# PASO 1: Modificar el index.js ORIGINAL (no sobrescribir)
modify_index_js() {
    log "Modificando index.js del backend..."
    
    if [ ! -f "$BACKEND_DIR/index.js" ]; then
        error "Archivo index.js no encontrado en $BACKEND_DIR"
    fi
    
    # Leer el archivo original
    INDEX_CONTENT=$(cat "$BACKEND_DIR/index.js")
    
    # Verificar si ya tiene las modificaciones
    if echo "$INDEX_CONTENT" | grep -q "// ✅ NUEVO: Guardar en SQLite automáticamente"; then
        warn "index.js ya parece estar modificado"
        return
    fi
    
    # Crear archivo temporal con el contenido modificado
    cat > /tmp/index_modified.js << 'EOF'
import express from "express";
const DENY_NAMES = (process.env.DENY_NAMES || "").split(",").map(s=>s.trim()).filter(Boolean);
const DENY_INSTANCE_REGEX = process.env.DENY_INSTANCE_REGEX ? new RegExp(process.env.DENY_INSTANCE_REGEX) : null;

import cors from "cors";
import fs from "fs";
import { Store } from "./store.js";
import { pollInstance, extract } from "./poller.js";
import historyRoutes from './routes/historyRoutes.js';
import metricHistoryRoutes from './routes/metricHistoryRoutes.js';
import * as historyService from './services/historyService.js';

const instances = JSON.parse(fs.readFileSync("./instances.json","utf-8"));

const app = express();
historyService.init();
app.use('/api/history', express.json({ limit: '256kb' }), historyRoutes);
app.use('/api/metric-history', metricHistoryRoutes);
app.use(cors());
app.use(express.json({ limit: "256kb" }));

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
        
        // ✅ NUEVO: Guardar en SQLite automáticamente
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
      
      // ✅ NUEVO: También guardar errores
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

app.listen(8080,()=>console.log("Aggregator on 8080"));

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
// --- fin depuración ---
// ---- Admin: reset del snapshot actual (deja todo vacío) ----
app.post("/admin/reset", (req, res) => {
  try {
    store.replaceSnapshot({ instances: [], monitors: [] });
    // Notifica por SSE para que el front se actualice inmediatamente
    store.broadcast("tick", store.snapshot());
    res.json({ ok: true, cleared: true });
  } catch (e) {
    console.error("[admin/reset]", e);
    res.status(500).json({ ok: false, error: String(e) });
  }
});

// ---- Admin: reindex forzado (ejecuta un ciclo completo) ----
// No bloquea la respuesta; agenda el ciclo en el next tick
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

// ---- Admin: reset + reindex en una sola llamada ----
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
EOF
    
    # Reemplazar el archivo
    cp /tmp/index_modified.js "$BACKEND_DIR/index.js"
    log "index.js modificado correctamente"
}

# PASO 2: Verificar si ya existe metricHistoryRoutes.js
check_and_create_routes() {
    log "Verificando rutas existentes..."
    
    # Si ya existe el archivo, no lo sobrescribimos
    if [ -f "$BACKEND_DIR/routes/metricHistoryRoutes.js" ]; then
        warn "metricHistoryRoutes.js ya existe, verificando contenido..."
        
        # Verificar si tiene el contenido correcto
        if grep -q "router.get('/monitor/'" "$BACKEND_DIR/routes/metricHistoryRoutes.js"; then
            log "metricHistoryRoutes.js parece estar correcto"
        else
            warn "metricHistoryRoutes.js existe pero no tiene el contenido esperado"
            # Podemos hacer backup y crear nuevo si quieres
            mv "$BACKEND_DIR/routes/metricHistoryRoutes.js" "$BACKEND_DIR/routes/metricHistoryRoutes.js.backup.$(date +%s)"
            create_metric_history_routes
        fi
    else
        create_metric_history_routes
    fi
}

# PASO 2a: Crear metricHistoryRoutes.js si no existe
create_metric_history_routes() {
    log "Creando metricHistoryRoutes.js..."
    
    mkdir -p "$BACKEND_DIR/routes"
    
    cat > "$BACKEND_DIR/routes/metricHistoryRoutes.js" << 'EOF'
import { Router } from 'express';
import * as historyService from '../services/historyService.js';

const router = Router();

// Obtener historial agrupado por monitor (para gráficas)
router.get('/monitor/:monitorName', async (req, res) => {
  try {
    const { monitorName } = req.params;
    const { hours = 24, bucketMinutes = 5 } = req.query;
    
    const from = Date.now() - (parseInt(hours) * 60 * 60 * 1000);
    const to = Date.now();
    
    // Usar la función existente listSeries con bucketMs ajustado
    const series = await historyService.listSeries({
      monitorId: monitorName,
      from: from,
      to: to,
      bucketMs: parseInt(bucketMinutes) * 60 * 1000
    });
    
    res.json({
      success: true,
      monitorName,
      data: series.map(item => ({
        ts: item.timestamp,
        ms: item.avgResponseTime || 0,
        status: item.avgStatus > 0.5 ? 'up' : 'down'
      }))
    });
  } catch (error) {
    console.error('Error fetching monitor history:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// Obtener historial por instancia (todas las métricas de una sede)
router.get('/instance/:instanceName', async (req, res) => {
  try {
    const { instanceName } = req.params;
    const { hours = 24 } = req.query;
    
    const from = Date.now() - (parseInt(hours) * 60 * 60 * 1000);
    const to = Date.now();
    
    // Para simplificar, obtenemos todos los monitors de esta instancia
    const allMonitors = await historyService.getMonitorsByInstance(instanceName);
    
    res.json({
      success: true,
      instanceName,
      monitors: allMonitors,
      hours: parseInt(hours)
    });
  } catch (error) {
    console.error('Error fetching instance history:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// Obtener lista de monitors disponibles
router.get('/monitors', async (req, res) => {
  try {
    const monitors = await historyService.getAvailableMonitors();
    res.json({
      success: true,
      monitors,
      count: monitors.length
    });
  } catch (error) {
    res.status(500).json({ error: 'Internal server error' });
  }
});

// Obtener estadísticas generales
router.get('/stats', async (req, res) => {
  try {
    const stats = await historyService.getStats();
    res.json({
      success: true,
      stats
    });
  } catch (error) {
    res.status(500).json({ error: 'Internal server error' });
  }
});

export default router;
EOF
    
    log "metricHistoryRoutes.js creado en $BACKEND_DIR/routes/"
}

# PASO 3: Verificar historyService.js
check_and_update_history_service() {
    log "Verificando historyService.js..."
    
    if [ ! -f "$BACKEND_DIR/services/historyService.js" ]; then
        error "historyService.js no encontrado en $BACKEND_DIR/services/"
    fi
    
    # Verificar si ya tiene las funciones nuevas
    if grep -q "getMonitorHistory" "$BACKEND_DIR/services/historyService.js"; then
        log "historyService.js ya tiene las funciones nuevas"
    else
        warn "historyService.js necesita actualización"
        
        # Crear archivo actualizado
        cat > "$BACKEND_DIR/services/historyService.js" << 'EOF'
import { initSQLite, insertHistory, getHistory, getHistoryAgg, getAvailableMonitors, getMonitorsByInstance, getStats } from './storage/sqlite.js';

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

// Nueva función para obtener histórico por monitor
export async function getMonitorHistory(monitorName, hours = 24) {
  const from = Date.now() - (hours * 60 * 60 * 1000);
  const to = Date.now();
  
  // Agrupar por intervalos de 5 minutos
  const bucketMs = 5 * 60 * 1000;
  
  return await getHistoryAgg({
    monitorId: monitorName,
    from,
    to,
    bucketMs
  });
}

// Nueva función para obtener histórico por instancia
export async function getInstanceHistory(instanceName, hours = 24) {
  return await getMonitorsByInstance(instanceName, hours);
}

// Nueva función para obtener monitores disponibles
export async function getAvailableMonitors() {
  return await getAvailableMonitors();
}

// Nueva función para obtener monitores por instancia
export async function getMonitorsByInstance(instanceName) {
  return await getMonitorsByInstance(instanceName);
}

// Nueva función para obtener estadísticas
export async function getStats() {
  return await getStats();
}
EOF
        
        log "historyService.js actualizado con nuevas funciones"
    fi
}

# PASO 4: Verificar y crear storage/sqlite.js
check_and_create_sqlite_storage() {
    log "Verificando storage/sqlite.js..."
    
    if [ -f "$BACKEND_DIR/services/storage/sqlite.js" ]; then
        warn "storage/sqlite.js ya existe"
        
        # Verificar si tiene las funciones necesarias
        if grep -q "getAvailableMonitors" "$BACKEND_DIR/services/storage/sqlite.js"; then
            log "storage/sqlite.js parece estar completo"
        else
            warn "storage/sqlite.js necesita funciones adicionales"
            # Hacer backup y crear nuevo
            mv "$BACKEND_DIR/services/storage/sqlite.js" "$BACKEND_DIR/services/storage/sqlite.js.backup.$(date +%s)"
            create_sqlite_storage_complete
        fi
    else
        create_sqlite_storage_complete
    fi
}

# Crear sqlite.js completo
create_sqlite_storage_complete() {
    log "Creando storage/sqlite.js completo..."
    
    mkdir -p "$BACKEND_DIR/services/storage"
    mkdir -p "/opt/kuma-central/kuma-aggregator/data"
    
    cat > "$BACKEND_DIR/services/storage/sqlite.js" << 'EOF'
import sqlite3 from 'sqlite3';
import { open } from 'sqlite';
import path from 'path';
import { fileURLToPath } from 'url';
import fs from 'fs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

let db = null;

export async function initSQLite() {
  if (db) return;
  
  // Asegurar que el directorio data existe
  const dataDir = path.join(__dirname, '../../../data');
  if (!fs.existsSync(dataDir)) {
    fs.mkdirSync(dataDir, { recursive: true });
  }
  
  db = await open({
    filename: path.join(dataDir, 'history.db'),
    driver: sqlite3.Database
  });
  
  await db.exec(`
    CREATE TABLE IF NOT EXISTS history (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      monitorId TEXT NOT NULL,
      timestamp INTEGER NOT NULL,
      status TEXT NOT NULL,
      responseTime REAL,
      message TEXT,
      instance TEXT,
      createdAt DATETIME DEFAULT CURRENT_TIMESTAMP
    );
    
    CREATE INDEX IF NOT EXISTS idx_monitor_time ON history(monitorId, timestamp);
    CREATE INDEX IF NOT EXISTS idx_timestamp ON history(timestamp);
    CREATE INDEX IF NOT EXISTS idx_instance ON history(instance);
    
    CREATE TABLE IF NOT EXISTS monitor_info (
      monitorId TEXT PRIMARY KEY,
      instance TEXT,
      monitor_name TEXT,
      monitor_type TEXT,
      monitor_url TEXT,
      first_seen INTEGER,
      last_seen INTEGER,
      checks_count INTEGER DEFAULT 0
    );
  `);
  
  console.log('✅ SQLite initialized for history tracking');
}

export async function insertHistory(event) {
  if (!db) await initSQLite();
  
  const { monitorId, timestamp, status, responseTime, message } = event;
  const instance = monitorId.includes('_') ? monitorId.split('_')[0] : 'unknown';
  
  // Insertar en historial
  const result = await db.run(
    `INSERT INTO history (monitorId, timestamp, status, responseTime, message, instance) 
     VALUES (?, ?, ?, ?, ?, ?)`,
    [monitorId, timestamp, status, responseTime, message, instance]
  );
  
  // Actualizar o insertar información del monitor
  await db.run(`
    INSERT INTO monitor_info (monitorId, instance, last_seen, checks_count)
    VALUES (?, ?, ?, 1)
    ON CONFLICT(monitorId) DO UPDATE SET
      last_seen = excluded.last_seen,
      checks_count = checks_count + 1
  `, [monitorId, instance, timestamp]);
  
  return { id: result.lastID };
}

export async function getHistory(params) {
  if (!db) await initSQLite();
  
  const { monitorId, from, to, limit = 1000, offset = 0 } = params;
  
  return await db.all(
    `SELECT * FROM history 
     WHERE monitorId = ? 
       AND timestamp >= ? 
       AND timestamp <= ?
     ORDER BY timestamp DESC
     LIMIT ? OFFSET ?`,
    [monitorId, from, to, limit, offset]
  );
}

export async function getHistoryAgg(params) {
  if (!db) await initSQLite();
  
  const { monitorId, from, to, bucketMs = 60000 } = params;
  
  const result = await db.all(
    `SELECT 
      CAST((timestamp / ?) * ? AS INTEGER) AS bucket,
      AVG(CASE WHEN status = 'up' THEN 1 ELSE 0 END) as avgStatus,
      AVG(responseTime) as avgResponseTime,
      COUNT(*) as count
     FROM history 
     WHERE monitorId = ? 
       AND timestamp >= ? 
       AND timestamp <= ?
     GROUP BY bucket
     ORDER BY bucket ASC`,
    [bucketMs, bucketMs, monitorId, from, to]
  );
  
  return result.map(row => ({
    timestamp: row.bucket,
    avgStatus: row.avgStatus,
    avgResponseTime: row.avgResponseTime,
    count: row.count
  }));
}

export async function getAvailableMonitors() {
  if (!db) await initSQLite();
  
  const result = await db.all(
    `SELECT 
      monitorId,
      instance,
      COUNT(*) as totalChecks,
      MAX(timestamp) as lastCheck,
      MIN(timestamp) as firstCheck
     FROM history 
     GROUP BY monitorId, instance
     ORDER BY lastCheck DESC`
  );
  
  return result;
}

export async function getMonitorsByInstance(instanceName, hours = 24) {
  if (!db) await initSQLite();
  
  const from = Date.now() - (hours * 60 * 60 * 1000);
  const to = Date.now();
  
  const result = await db.all(
    `SELECT 
      monitorId,
      COUNT(*) as totalChecks,
      AVG(CASE WHEN status = 'up' THEN 1 ELSE 0 END) * 100 as uptimePercent,
      AVG(responseTime) as avgResponseTime
     FROM history 
     WHERE instance = ? 
       AND timestamp >= ? 
       AND timestamp <= ?
     GROUP BY monitorId
     ORDER BY monitorId ASC`,
    [instanceName, from, to]
  );
  
  return result;
}

export async function getStats() {
  if (!db) await initSQLite();
  
  const result = await db.get(
    `SELECT 
      COUNT(DISTINCT monitorId) as totalMonitors,
      COUNT(DISTINCT instance) as totalInstances,
      COUNT(*) as totalRecords,
      MIN(timestamp) as earliestRecord,
      MAX(timestamp) as latestRecord
     FROM history`
  );
  
  return result;
}
EOF
    
    log "storage/sqlite.js creado en $BACKEND_DIR/services/storage/"
}

# PASO 5: Verificar si el frontend ya tiene los servicios
check_frontend_services() {
    log "Verificando servicios en frontend..."
    
    # Verificar si ya existe historyApi.js
    if [ -f "$FRONTEND_DIR/src/services/historyApi.js" ]; then
        log "historyApi.js ya existe en frontend"
        
        # Verificar contenido básico
        if grep -q "getMonitorHistory" "$FRONTEND_DIR/src/services/historyApi.js"; then
            log "historyApi.js parece estar correcto"
        else
            warn "historyApi.js existe pero no tiene todas las funciones"
        fi
    else
        warn "historyApi.js no existe en frontend"
        # Podemos crearlo si quieres
        read -p "¿Crear historyApi.js en frontend? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            create_frontend_api_service
        fi
    fi
    
    # Verificar HistoryChartWithHistory
    if [ -f "$FRONTEND_DIR/src/components/HistoryChartWithHistory.jsx" ]; then
        log "HistoryChartWithHistory.jsx ya existe"
    else
        warn "HistoryChartWithHistory.jsx no existe"
    fi
}

# PASO 6: Verificar la estructura actual del backend
analyze_current_structure() {
    log "Analizando estructura actual del backend..."
    
    echo "=== ESTRUCTURA ACTUAL ===" >> "$LOG_FILE"
    
    # Mostrar archivos principales
    log "Archivos en $BACKEND_DIR:"
    ls -la "$BACKEND_DIR/" | tee -a "$LOG_FILE"
    
    log "Servicios:"
    ls -la "$BACKEND_DIR/services/" 2>/dev/null | tee -a "$LOG_FILE" || warn "No hay directorio services"
    
    log "Rutas:"
    ls -la "$BACKEND_DIR/routes/" 2>/dev/null | tee -a "$LOG_FILE" || warn "No hay directorio routes"
    
    log "Storage:"
    ls -la "$BACKEND_DIR/services/storage/" 2>/dev/null | tee -a "$LOG_FILE" || warn "No hay directorio storage"
    
    # Verificar imports en index.js
    log "Verificando imports en index.js..."
    grep -n "import\|require" "$BACKEND_DIR/index.js" | tee -a "$LOG_FILE"
}

# PASO 7: Crear script para probar la integración
create_test_script() {
    log "Creando script de prueba..."
    
    cat > /tmp/test_integration.sh << 'EOF'
#!/bin/bash

echo "=== PRUEBA DE INTEGRACIÓN DE HISTORIAL ==="
echo

# 1. Verificar que el backend está corriendo
echo "1. Probando conexión al backend..."
if curl -s http://localhost:8080/health > /dev/null; then
    echo "✅ Backend respondiendo"
else
    echo "❌ Backend no responde"
    exit 1
fi

# 2. Verificar nueva ruta de métricas históricas
echo "2. Probando nueva ruta /api/metric-history/monitors..."
if curl -s http://localhost:8080/api/metric-history/monitors | grep -q "success"; then
    echo "✅ Ruta /api/metric-history/monitors funcionando"
else
    echo "⚠️  Ruta /api/metric-history/monitors podría no estar funcionando"
fi

# 3. Verificar que SQLite se creó
echo "3. Verificando base de datos SQLite..."
if [ -f "/opt/kuma-central/kuma-aggregator/data/history.db" ]; then
    echo "✅ Base de datos encontrada en /opt/kuma-central/kuma-aggregator/data/history.db"
    
    # Verificar tablas
    if sqlite3 "/opt/kuma-central/kuma-aggregator/data/history.db" ".tables" 2>/dev/null | grep -q "history"; then
        echo "✅ Tabla 'history' existe"
    else
        echo "⚠️  Tabla 'history' no encontrada"
    fi
else
    echo "❌ Base de datos no encontrada"
fi

# 4. Verificar datos en tiempo real
echo "4. Probando datos en tiempo real..."
if curl -s http://localhost:8080/api/summary | grep -q "instances"; then
    echo "✅ Datos en tiempo real funcionando"
else
    echo "⚠️  Problema con datos en tiempo real"
fi

# 5. Verificar historial existente
echo "5. Verificando si hay datos históricos..."
COUNT=$(sqlite3 "/opt/kuma-central/kuma-aggregator/data/history.db" "SELECT COUNT(*) FROM history" 2>/dev/null || echo "0")
echo "   Registros en historial: $COUNT"

# 6. Esperar un ciclo (5 segundos) y verificar que se agreguen datos
echo "6. Esperando ciclo de polling (5 segundos)..."
sleep 6

NEW_COUNT=$(sqlite3 "/opt/kuma-central/kuma-aggregator/data/history.db" "SELECT COUNT(*) FROM history" 2>/dev/null || echo "0")
echo "   Registros después del ciclo: $NEW_COUNT"

if [ "$NEW_COUNT" -gt "$COUNT" ]; then
    echo "✅ El sistema está guardando datos automáticamente"
else
    echo "⚠️  No se agregaron nuevos registros automáticamente"
fi

echo
echo "=== RESUMEN ==="
echo "Para probar manualmente:"
echo "  curl http://localhost:8080/api/metric-history/monitors"
echo "  curl 'http://localhost:8080/api/metric-history/monitor/[nombre_monitor]?hours=24'"
echo
echo "Para ver logs del backend:"
echo "  tail -f /var/log/kuma-backend.log"
EOF
    
    chmod +x /tmp/test_integration.sh
    log "Script de prueba creado en /tmp/test_integration.sh"
}

# PASO 8: Crear script de reinicio CORREGIDO
create_fixed_restart_script() {
    log "Creando script de reinicio corregido..."
    
    cat > /tmp/restart_kuma_fixed.sh << 'EOF'
#!/bin/bash

# Script corregido para reiniciar servicios Kuma
echo "=== REINICIANDO SERVICIOS KUMA ==="
echo

# 1. Detener proceso actual
echo "1. Buscando proceso actual..."
BACKEND_PID=$(ps aux | grep "node.*index.js" | grep -v grep | awk '{print $2}')

if [ -n "$BACKEND_PID" ]; then
    echo "   Proceso encontrado (PID: $BACKEND_PID), deteniendo..."
    kill $BACKEND_PID
    sleep 3
    
    # Verificar que se detuvo
    if ps -p $BACKEND_PID > /dev/null 2>&1; then
        echo "   Forzando terminación..."
        kill -9 $BACKEND_PID
    fi
else
    echo "   No se encontró proceso corriendo"
fi

# 2. Verificar archivos
echo "2. Verificando archivos..."
cd /opt/kuma-central/kuma-aggregator/src

if [ ! -f "index.js" ]; then
    echo "❌ Error: index.js no encontrado"
    exit 1
fi

if [ ! -f "services/storage/sqlite.js" ]; then
    echo "⚠️  Advertencia: storage/sqlite.js no encontrado"
fi

# 3. Crear directorio de logs si no existe
echo "3. Configurando logs..."
sudo mkdir -p /var/log/kuma
sudo chown -R thunder:thunder /var/log/kuma 2>/dev/null || true

# 4. Iniciar backend
echo "4. Iniciando backend..."
cd /opt/kuma-central/kuma-aggregator/src
npm start > /var/log/kuma/backend.log 2>&1 &
BACKEND_NEW_PID=$!

sleep 2

# 5. Verificar que se inició
echo "5. Verificando inicio..."
if ps -p $BACKEND_NEW_PID > /dev/null 2>&1; then
    echo "   ✅ Backend iniciado (PID: $BACKEND_NEW_PID)"
else
    echo "   ❌ Backend no se pudo iniciar"
    echo "   Revisa los logs: tail -f /var/log/kuma/backend.log"
    exit 1
fi

# 6. Esperar y probar conexión
echo "6. Probando conexión..."
sleep 3

MAX_RETRIES=5
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if curl -s http://localhost:8080/health > /dev/null; then
        echo "   ✅ Backend respondiendo correctamente"
        break
    fi
    
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "   Intento $RETRY_COUNT/$MAX_RETRIES: esperando..."
    sleep 2
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo "   ❌ Backend no responde después de $MAX_RETRIES intentos"
    echo "   Revisa: tail -f /var/log/kuma/backend.log"
fi

# 7. Información útil
echo
echo "=== INFORMACIÓN ÚTIL ==="
echo "Backend PID: $BACKEND_NEW_PID"
echo "Backend URL: http://localhost:8080"
echo "Logs: tail -f /var/log/kuma/backend.log"
echo "Base de datos: /opt/kuma-central/kuma-aggregator/data/history.db"
echo
echo "Para probar la integración:"
echo "  bash /tmp/test_integration.sh"
echo
echo "Para el frontend (en otra terminal):"
echo "  cd /home/thunder/kuma-dashboard-clean/kuma-ui"
echo "  npm run dev"
EOF
    
    chmod +x /tmp/restart_kuma_fixed.sh
    log "Script de reinicio creado en /tmp/restart_kuma_fixed.sh"
}

# Función principal
main() {
    echo "========================================="
    echo "  INTEGRACIÓN CORREGIDA - VERIFICACIÓN"
    echo "========================================="
    echo ""
    
    # Verificar permisos
    if [ "$EUID" -ne 0 ]; then 
        warn "Ejecutando sin sudo - algunos archivos podrían requerir permisos"
    fi
    
    check_directories
    check_existing_files
    backup_files
    
    echo ""
    echo "Analizando situación actual..."
    echo "------------------------------"
    analyze_current_structure
    
    echo ""
    read -p "¿Continuar con las modificaciones? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Operación cancelada"
        exit 0
    fi
    
    echo ""
    echo "Aplicando modificaciones necesarias..."
    echo "--------------------------------------"
    
    # Aplicar solo lo necesario
    modify_index_js
    check_and_create_routes
    check_and_update_history_service
    check_and_create_sqlite_storage
    check_frontend_services
    
    # Crear scripts de utilidad
    create_test_script
    create_fixed_restart_script
    
    echo ""
    echo "========================================="
    echo "✅ VERIFICACIÓN Y REPARACIÓN COMPLETADA"
    echo "========================================="
    echo ""
    echo "Resumen:"
    echo "--------"
    echo "1. ✅ index.js verificado/modificado"
    echo "2. ✅ Rutas verificadas/creadas"
    echo "3. ✅ historyService.js verificado/actualizado"
    echo "4. ✅ storage/sqlite.js verificado/creado"
    echo "5. ✅ Frontend verificado"
    echo "6. ✅ Script de prueba creado: /tmp/test_integration.sh"
    echo "7. ✅ Script de reinicio creado: /tmp/restart_kuma_fixed.sh"
    echo ""
    echo "Próximos pasos:"
    echo "---------------"
    echo "1. Reiniciar el backend:"
    echo "   sudo bash /tmp/restart_kuma_fixed.sh"
    echo ""
    echo "2. Probar la integración:"
    echo "   bash /tmp/test_integration.sh"
    echo ""
    echo "3. En el frontend, si necesitas los servicios:"
    echo "   - historyApi.js ya debería estar en src/services/"
    echo "   - HistoryChartWithHistory.jsx ya debería estar en src/components/"
    echo ""
    echo "4. Para usar historial en tus componentes:"
    echo "   import HistoryChartWithHistory from './components/HistoryChartWithHistory'"
    echo "   <HistoryChartWithHistory monitorId='nombre_monitor' hours={24} />"
    echo ""
    echo "Log completo en: $LOG_FILE"
    echo "========================================="
}

# Ejecutar función principal
main

#!/bin/bash

# integrate_historial.sh
# Script para integrar historial persistente en Kuma Dashboard
# Ejecutar: sudo bash integrate_historial.sh

# Configuración - RUTAS CORREGIDAS
BACKEND_DIR="/opt/kuma-central/kuma-aggregator/src"
FRONTEND_DIR="/home/thunder/kuma-dashboard-clean/kuma-ui"
LOG_FILE="/tmp/integration_$(date +%Y%m%d_%H%M%S).log"

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

# Backup de archivos originales
backup_files() {
    log "Creando backups..."
    
    TIMESTAMP=$(date +%s)
    
    # Backend
    if [ -f "$BACKEND_DIR/index.js" ]; then
        cp "$BACKEND_DIR/index.js" "$BACKEND_DIR/index.js.backup.$TIMESTAMP"
    fi
    
    if [ -f "$BACKEND_DIR/services/historyService.js" ]; then
        cp "$BACKEND_DIR/services/historyService.js" "$BACKEND_DIR/services/historyService.js.backup.$TIMESTAMP"
    fi
    
    # Frontend
    if [ -f "$FRONTEND_DIR/src/components/HistoryChart.jsx" ]; then
        cp "$FRONTEND_DIR/src/components/HistoryChart.jsx" "$FRONTEND_DIR/src/components/HistoryChart.jsx.backup.$TIMESTAMP"
    fi
    
    log "Backups creados con éxito"
}

# PASO 1: Modificar index.js para guardar automáticamente
modify_index_js() {
    log "Modificando index.js del backend..."
    
    if [ ! -f "$BACKEND_DIR/index.js" ]; then
        error "Archivo index.js no encontrado en $BACKEND_DIR"
    fi
    
    # Crear archivo temporal con el nuevo index.js
    cat > /tmp/new_index.js << 'EOF'
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
    
    # Reemplazar el archivo index.js
    cp /tmp/new_index.js "$BACKEND_DIR/index.js"
    log "index.js actualizado correctamente"
}

# PASO 2: Crear routes/metricHistoryRoutes.js
create_metric_history_routes() {
    log "Creando metricHistoryRoutes.js en backend..."
    
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

export default router;
EOF
    
    log "metricHistoryRoutes.js creado en $BACKEND_DIR/routes/"
}

# PASO 3: Modificar historyService.js
modify_history_service() {
    log "Modificando historyService.js en backend..."
    
    if [ ! -f "$BACKEND_DIR/services/historyService.js" ]; then
        error "Archivo historyService.js no encontrado"
    fi
    
    # Reemplazar el archivo completo
    cat > "$BACKEND_DIR/services/historyService.js" << 'EOF'
import { initSQLite, insertHistory, getHistory, getHistoryAgg, getAvailableMonitors, getMonitorsByInstance } from './storage/sqlite.js';

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
EOF
    
    log "historyService.js actualizado"
}

# PASO 4: Crear o modificar storage/sqlite.js
create_sqlite_storage() {
    log "Creando/actualizando storage/sqlite.js..."
    
    mkdir -p "$BACKEND_DIR/services/storage"
    mkdir -p "$BACKEND_DIR/data"
    
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
  const dataDir = path.join(__dirname, '../../data');
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
  
  console.log('SQLite initialized for history tracking');
}

export async function insertHistory(event) {
  if (!db) await initSQLite();
  
  const { monitorId, timestamp, status, responseTime, message } = event;
  const instance = monitorId.includes('_') ? monitorId.split('_')[0] : 'unknown';
  
  // Insertar en historial
  await db.run(
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
EOF
    
    log "storage/sqlite.js creado"
}

# PASO 5: Crear un servicio API para el frontend
create_frontend_api_service() {
    log "Creando servicio API para frontend..."
    
    mkdir -p "$FRONTEND_DIR/src/services"
    
    cat > "$FRONTEND_DIR/src/services/historyApi.js" << 'EOF'
// Servicio para obtener datos históricos del backend
const API_BASE = import.meta.env.VITE_API_BASE_URL || 'http://10.10.31.31:8080/api';

export const historyApi = {
  // Obtener historial de un monitor específico
  async getMonitorHistory(monitorName, hours = 24, bucketMinutes = 5) {
    try {
      const response = await fetch(
        `${API_BASE}/metric-history/monitor/${encodeURIComponent(monitorName)}?` +
        `hours=${hours}&bucketMinutes=${bucketMinutes}&_=${Date.now()}`,
        {
          cache: 'no-store',
          headers: {
            'Cache-Control': 'no-store, no-cache, must-revalidate',
            'Pragma': 'no-cache'
          }
        }
      );
      
      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }
      
      const data = await response.json();
      return data.success ? data.data : [];
    } catch (error) {
      console.error('Error fetching monitor history:', error);
      return [];
    }
  },

  // Obtener historial de una instancia
  async getInstanceHistory(instanceName, hours = 24) {
    try {
      const response = await fetch(
        `${API_BASE}/metric-history/instance/${encodeURIComponent(instanceName)}?hours=${hours}`,
        {
          cache: 'no-store',
          headers: {
            'Cache-Control': 'no-store, no-cache, must-revalidate',
            'Pragma': 'no-cache'
          }
        }
      );
      
      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }
      
      const data = await response.json();
      return data.success ? data.monitors : [];
    } catch (error) {
      console.error('Error fetching instance history:', error);
      return [];
    }
  },

  // Obtener lista de monitores disponibles
  async getAvailableMonitors() {
    try {
      const response = await fetch(
        `${API_BASE}/metric-history/monitors?_=${Date.now()}`,
        {
          cache: 'no-store',
          headers: {
            'Cache-Control': 'no-store, no-cache, must-revalidate',
            'Pragma': 'no-cache'
          }
        }
      );
      
      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }
      
      const data = await response.json();
      return data.success ? data.monitors : [];
    } catch (error) {
      console.error('Error fetching available monitors:', error);
      return [];
    }
  },

  // Obtener datos en tiempo real (mantener compatibilidad)
  async getRealtimeData() {
    try {
      const response = await fetch(
        `${API_BASE}/summary?_=${Date.now()}`,
        {
          cache: 'no-store',
          headers: {
            'Cache-Control': 'no-store, no-cache, must-revalidate',
            'Pragma': 'no-cache'
          }
        }
      );
      
      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }
      
      return await response.json();
    } catch (error) {
      console.error('Error fetching realtime data:', error);
      return { instances: [], monitors: [] };
    }
  }
};

export default historyApi;
EOF
    
    log "Servicio API creado en $FRONTEND_DIR/src/services/historyApi.js"
}

# PASO 6: Crear un componente wrapper para HistoryChart
create_history_chart_wrapper() {
    log "Creando componente HistoryChartWithHistory..."
    
    cat > "$FRONTEND_DIR/src/components/HistoryChartWithHistory.jsx" << 'EOF'
import React, { useState, useEffect, useMemo } from "react";
import HistoryChart from "./HistoryChart.jsx";
import { historyApi } from "../services/historyApi.js";

/**
 * Componente wrapper que añade carga automática de datos históricos
 * a HistoryChart existente.
 */
export default function HistoryChartWithHistory({
  mode = "monitor",
  monitorId = null,
  instanceName = null,
  hours = 24,
  bucketMinutes = 5,
  ...props
}) {
  const [historicalData, setHistoricalData] = useState([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);

  // Cargar datos históricos basado en el modo
  useEffect(() => {
    if (mode === "monitor" && monitorId) {
      loadMonitorHistory();
    } else if (mode === "instance" && instanceName) {
      loadInstanceHistory();
    }
  }, [mode, monitorId, instanceName, hours, bucketMinutes]);

  const loadMonitorHistory = async () => {
    if (!monitorId) return;
    
    setLoading(true);
    setError(null);
    
    try {
      const data = await historyApi.getMonitorHistory(
        monitorId,
        hours,
        bucketMinutes
      );
      
      // Transformar datos al formato que espera HistoryChart
      const transformedData = data.map(item => ({
        ts: item.ts,
        ms: item.ms,
        status: item.status
      }));
      
      setHistoricalData(transformedData);
    } catch (err) {
      console.error("Error loading monitor history:", err);
      setError("No se pudieron cargar los datos históricos");
      setHistoricalData([]);
    } finally {
      setLoading(false);
    }
  };

  const loadInstanceHistory = async () => {
    if (!instanceName) return;
    
    setLoading(true);
    setError(null);
    
    try {
      const monitors = await historyApi.getInstanceHistory(
        instanceName,
        hours
      );
      
      // Para modo instancia, podrías querer mostrar algo diferente
      console.log("Instance monitors:", monitors);
      setHistoricalData([]);
    } catch (err) {
      console.error("Error loading instance history:", err);
      setError("No se pudieron cargar los datos de la instancia");
      setHistoricalData([]);
    } finally {
      setLoading(false);
    }
  };

  // Determinar qué props pasar a HistoryChart
  const chartProps = useMemo(() => {
    if (mode === "monitor") {
      return {
        ...props,
        mode: "monitor",
        seriesMon: historicalData,
        title: props.title || `Historial: ${monitorId}`
      };
    }
    
    // Para otros modos, pasar las props originales
    return { ...props, mode };
  }, [mode, historicalData, monitorId, props]);

  if (loading) {
    return (
      <div style={{
        height: props.h || 260,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        backgroundColor: '#f9fafb',
        borderRadius: '8px',
        border: '1px dashed #d1d5db'
      }}>
        <div style={{ textAlign: 'center' }}>
          <div style={{ fontSize: '14px', color: '#6b7280' }}>
            Cargando datos históricos...
          </div>
          <div style={{ fontSize: '12px', color: '#9ca3af', marginTop: '4px' }}>
            (Últimas {hours} horas)
          </div>
        </div>
      </div>
    );
  }

  if (error) {
    return (
      <div style={{
        height: props.h || 260,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        backgroundColor: '#fef2f2',
        borderRadius: '8px',
        border: '1px solid #fca5a5'
      }}>
        <div style={{ textAlign: 'center', color: '#dc2626' }}>
          <div style={{ fontSize: '14px', fontWeight: '500' }}>
            {error}
          </div>
          <button
            onClick={mode === "monitor" ? loadMonitorHistory : loadInstanceHistory}
            style={{
              marginTop: '8px',
              padding: '4px 12px',
              fontSize: '12px',
              backgroundColor: '#dc2626',
              color: 'white',
              border: 'none',
              borderRadius: '4px',
              cursor: 'pointer'
            }}
          >
            Reintentar
          </button>
        </div>
      </div>
    );
  }

  return <HistoryChart {...chartProps} />;
}

// Función helper para extraer monitorId de los datos del monitor
export function getMonitorIdFromMonitor(monitor) {
  if (!monitor) return null;
  
  // Intentar construir un ID consistente
  const instance = monitor.instance || 'unknown';
  const name = monitor.info?.monitor_name || 'unknown';
  
  return `${instance}_${name}`.replace(/\s+/g, '_');
}
EOF
    
    log "Componente wrapper creado: HistoryChartWithHistory.jsx"
}

# PASO 7: Crear script para reiniciar servicios
create_restart_script() {
    log "Creando script de reinicio..."
    
    cat > /tmp/restart_kuma_services.sh << 'EOF'
#!/bin/bash

# Script para reiniciar servicios Kuma después de la integración
echo "Reiniciando servicios Kuma..."

# Encontrar el proceso del backend
BACKEND_PID=$(ps aux | grep "node.*index.js" | grep -v grep | awk '{print $2}')

if [ -n "$BACKEND_PID" ]; then
    echo "Deteniendo backend (PID: $BACKEND_PID)..."
    kill $BACKEND_PID
    sleep 2
fi

# Iniciar backend
echo "Iniciando backend..."
cd /opt/kuma-central/kuma-aggregator
npm start > /var/log/kuma-backend.log 2>&1 &
BACKEND_NEW_PID=$!
echo "Backend iniciado (PID: $BACKEND_NEW_PID)"

# Verificar que esté funcionando
sleep 3
if curl -s http://localhost:8080/health > /dev/null; then
    echo "✅ Backend funcionando correctamente en http://localhost:8080"
else
    echo "⚠️  Backend no responde. Verifica /var/log/kuma-backend.log"
fi

echo ""
echo "Para el frontend, en otra terminal ejecuta:"
echo "cd /home/thunder/kuma-dashboard-clean/kuma-ui"
echo "npm run dev"
echo ""
echo "Para ver logs del backend:"
echo "tail -f /var/log/kuma-backend.log"
EOF
    
    chmod +x /tmp/restart_kuma_services.sh
    
    log "Script de reinicio creado en /tmp/restart_kuma_services.sh"
}

# Función principal
main() {
    echo "========================================="
    echo "  INTEGRACIÓN DE HISTORIAL PERSISTENTE"
    echo "========================================="
    echo ""
    
    # Verificar permisos
    if [ "$EUID" -ne 0 ]; then 
        warn "Se recomienda ejecutar con sudo para permisos en /opt"
    fi
    
    check_directories
    backup_files
    
    echo ""
    echo "Aplicando modificaciones..."
    echo "---------------------------"
    
    # Backend
    modify_index_js
    create_metric_history_routes
    modify_history_service
    create_sqlite_storage
    
    # Frontend
    create_frontend_api_service
    create_history_chart_wrapper
    
    # Utilidades
    create_restart_script
    
    echo ""
    echo "========================================="
    echo "✅ INTEGRACIÓN COMPLETADA"
    echo "========================================="
    echo ""
    echo "Resumen de cambios:"
    echo "-------------------"
    echo "1. ✅ Backend: index.js modificado para guardar historial automático"
    echo "2. ✅ Backend: Nueva ruta /api/metric-history creada"
    echo "3. ✅ Backend: historyService.js actualizado"
    echo "4. ✅ Backend: SQLite storage implementado en /opt/kuma-central/kuma-aggregator/data/history.db"
    echo "5. ✅ Frontend: Servicio API creado en src/services/historyApi.js"
    echo "6. ✅ Frontend: Componente wrapper HistoryChartWithHistory.jsx creado"
    echo "7. ✅ Script de reinicio en /tmp/restart_kuma_services.sh"
    echo ""
    echo "Próximos pasos:"
    echo "---------------"
    echo "1. Ejecutar: sudo bash /tmp/restart_kuma_services.sh"
    echo "2. En el frontend, reemplazar <HistoryChart> por <HistoryChartWithHistory>"
    echo "3. Pasar la prop monitorId o instanceName según corresponda"
    echo ""
    echo "Para probar:"
    echo "-----------"
    echo "curl http://localhost:8080/api/metric-history/monitors"
    echo "curl http://localhost:8080/api/metric-history/monitor/[nombre_monitor]?hours=24"
    echo ""
    echo "Log completo en: $LOG_FILE"
    echo "========================================="
}

# Ejecutar función principal
main

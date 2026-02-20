// /opt/kuma-central/kuma-aggregator/src/index.js
import combustibleRoutes from './routes/combustible.routes.js';
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

// Endpoint de promedios
import instanceAveragesRoutes from './routes/instanceAveragesRoutes.js';

const instances = JSON.parse(fs.readFileSync("./instances.json","utf-8"));

const app = express();
await historyService.init();

// Objeto global para guardar últimos estados de plantas
global.ultimosEstadosPlantas = {};

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
app.use('/api/combustible', combustibleRoutes);
app.use('/api/instance/averages', instanceAveragesRoutes);

const store = new Store();

async function cycle() {
  const nextInstances = [];
  const nextMonitors  = [];

  for (const inst of instances) {
    try {
      // Ahora pollInstance devuelve { metrics, tagsMap }
      const result = await pollInstance(inst);
      const extracted = extract(result); // Pasamos todo el resultado que incluye tagsMap
      
      nextInstances.push({ name: inst.name, ok: true });
      
      for (const m of extracted) {
        nextMonitors.push({ instance: inst.name, ...m });
        
        // Guardar en SQLite automáticamente (incluyendo tags)
        await historyService.addEvent({
          monitorId: `${inst.name}_${m.info?.monitor_name}`.replace(/\s+/g, '_'),
          timestamp: Date.now(),
          status: m.latest?.status === 1 ? 'up' : 'down',
          responseTime: m.latest?.responseTime || null,
          tags: m.info?.tags || [],
          instance: inst.name,
          message: null
        });

        // Detectar cambios en plantas eléctricas
        const nombreMonitor = m.info?.monitor_name;
        if (nombreMonitor && nombreMonitor.startsWith('PLANTA')) {
          const estadoActual = m.latest?.status === 1 ? 'UP' : 'DOWN';
          const estadoAnterior = global.ultimosEstadosPlantas[nombreMonitor];
          
          // Si es la primera vez que vemos esta planta o cambió de estado
          if (!estadoAnterior || estadoAnterior !== estadoActual) {
            console.log(`⚡ Cambio detectado en ${nombreMonitor}: ${estadoAnterior || 'NUEVA'} → ${estadoActual}`);
            
            // Notificar a la API de combustible (sin esperar respuesta)
            fetch('http://10.10.31.31:8080/api/combustible/evento', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({
                nombre_monitor: nombreMonitor,
                estado: estadoActual
              })
            }).catch(e => console.error(`Error notificando cambio de ${nombreMonitor}:`, e.message));
          }
          
          // Guardar nuevo estado
          global.ultimosEstadosPlantas[nombreMonitor] = estadoActual;
        }
      }
    } catch (error) {
      nextInstances.push({ name: inst.name, ok: false });
      
      // Guardar errores
      await historyService.addEvent({
        monitorId: `${inst.name}_error`,
        timestamp: Date.now(),
        status: 'down',
        responseTime: null,
        message: `Error polling: ${error.message}`,
        instance: inst.name,
        tags: []
      });
    }
  }

  // Purga y reemplaza el estado (sin fantasmas)
  store.replaceSnapshot({ instances: nextInstances, monitors: nextMonitors });

  // Notifica a suscriptores SSE
  store.broadcast("tick", store.snapshot());

  // Debug: log por ciclo para LOG_TARGET
  const LOG_TARGET = process.env.LOG_TARGET || '';
  if (LOG_TARGET) {
    const snap = store.snapshot();
    const hits = snap.monitors.filter(m => (m.info?.monitor_name === LOG_TARGET));
    if (hits.length > 0) {
      const byInst = {}; 
      hits.forEach(h => { byInst[h.instance] = (byInst[h.instance]||0) + 1; });
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

// Endpoints de depuración
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

// Endpoint para debug de tags
app.get("/debug/tags", (req, res) => {
  try {
    const s = store.snapshot();
    const plantasConTags = s.monitors
      .filter(m => m.info?.monitor_name?.startsWith('PLANTA'))
      .map(m => ({
        nombre: m.info?.monitor_name,
        instance: m.instance,
        tags: m.info?.tags || [],
        sede: Array.isArray(m.info?.tags) ? m.info.tags.find(t => 
          typeof t === 'string' && 
          ['Caracas', 'Guanare', 'Valencia', 'Maracaibo', 'Barquisimeto',
           'San Felipe', 'Los Teques', 'La Guaira', 'Miranda', 'Zulia',
           'Táchira', 'Mérida', 'Trujillo', 'Cojedes', 'Portuguesa',
           'Barinas', 'Apure', 'Guárico', 'Anzoátegui', 'Monagas', 'Sucre',
           'Nueva Esparta', 'Bolívar', 'Amazonas', 'Delta Amacuro'].includes(t)
        ) : 'No detectada'
      }));
    
    res.json({
      success: true,
      total: plantasConTags.length,
      plantas: plantasConTags,
      timestamp: Date.now()
    });
  } catch (error) {
    res.status(500).json({ 
      success: false, 
      error: error.message 
    });
  }
});

// Admin: reset del snapshot actual
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

// Admin: reindex forzado
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

// Admin: reset + reindex
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

// Admin: Limpiar monitores fantasma
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

app.listen(8080, () => console.log("✅ Aggregator on 8080"));

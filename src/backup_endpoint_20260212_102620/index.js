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
import instanceAverageRoutes from './routes/instanceAverageRoutes.js';

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
// ---- Admin: Limpiar monitores fantasma ----
app.post("/admin/cleanup-fantasma", async (req, res) => {
    try {
        const { cleanupInactiveMonitors } = await import('./services/storage/sqlite.js');
        const removed = await cleanupInactiveMonitors(1); // 1 minuto
        
        // Forzar ciclo para refrescar
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

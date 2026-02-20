// /opt/kuma-central/kuma-aggregator/src/services/historyService.js
import sqlite3 from 'sqlite3';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

let db = null;

function getDb() {
  if (!db) {
    const dbPath = join(__dirname, '../../data/history.db');
    db = new sqlite3.Database(dbPath);
    
    // Habilitar WAL mode y optimizaciones
    db.exec(`
      PRAGMA journal_mode=WAL;
      PRAGMA synchronous=NORMAL;
      PRAGMA busy_timeout=5000;
      PRAGMA cache_size=-2000;
    `, (err) => {
      if (err) {
        console.error('[SQLite] Error configurando:', err);
      } else {
        console.log('[SQLite] ✅ WAL mode enabled');
      }
    });
  }
  return db;
}

export async function init() {
  return new Promise((resolve, reject) => {
    const db = getDb();
    
    db.serialize(() => {
      // Crear tabla si no existe
      db.run(`
        CREATE TABLE IF NOT EXISTS monitor_history (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          monitorId TEXT NOT NULL,
          timestamp INTEGER NOT NULL,
          status TEXT NOT NULL,
          responseTime REAL,
          message TEXT,
          instance TEXT,
          tags TEXT
        )
      `);

      // Crear índices para mejorar performance
      db.run(`CREATE INDEX IF NOT EXISTS idx_monitorId ON monitor_history(monitorId)`);
      db.run(`CREATE INDEX IF NOT EXISTS idx_timestamp ON monitor_history(timestamp)`);
      
      console.log('[SQLite] ✅ Base de datos inicializada');
      resolve();
    });
  });
}

export async function addEvent(event) {
  return new Promise((resolve, reject) => {
    const db = getDb();
    const { monitorId, timestamp, status, responseTime, tags, message, instance } = event;
    
    const runInsert = (retryCount = 0) => {
      db.run(
        `INSERT INTO monitor_history 
         (monitorId, timestamp, status, responseTime, message, instance, tags) 
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
        [
          monitorId,
          timestamp,
          status,
          responseTime || null,
          message || null,
          instance || null,
          tags ? JSON.stringify(tags) : null
        ],
        function(err) {
          if (err) {
            if (err.code === 'SQLITE_BUSY' && retryCount < 5) {
              console.log(`[SQLite] Busy, reintentando (${retryCount + 1}/5)...`);
              setTimeout(() => runInsert(retryCount + 1), 200);
            } else {
              console.error('[SQLite] Error insertando:', err);
              reject(err);
            }
          } else {
            resolve(this.lastID);
          }
        }
      );
    };
    
    runInsert();
  });
}

export async function getHistory(monitorId, from, to, limit = 1000) {
  return new Promise((resolve, reject) => {
    const db = getDb();
    
    db.all(
      `SELECT * FROM monitor_history 
       WHERE monitorId = ? 
       AND timestamp BETWEEN ? AND ? 
       ORDER BY timestamp DESC 
       LIMIT ?`,
      [monitorId, from, to, limit],
      (err, rows) => {
        if (err) {
          console.error('[SQLite] Error consultando:', err);
          reject(err);
        } else {
          // Parsear tags si existen
          const parsed = rows.map(row => ({
            ...row,
            tags: row.tags ? JSON.parse(row.tags) : null
          }));
          resolve(parsed);
        }
      }
    );
  });
}

export async function cleanupInactiveMonitors(daysOld = 30) {
  return new Promise((resolve, reject) => {
    const db = getDb();
    const cutoff = Date.now() - (daysOld * 24 * 60 * 60 * 1000);
    
    db.run(
      `DELETE FROM monitor_history WHERE timestamp < ?`,
      [cutoff],
      function(err) {
        if (err) {
          console.error('[SQLite] Error limpiando:', err);
          reject(err);
        } else {
          console.log(`[SQLite] ✅ Limpiados ${this.changes} registros antiguos`);
          resolve(this.changes);
        }
      }
    );
  });
}

export default {
  init,
  addEvent,
  getHistory,
  cleanupInactiveMonitors
};

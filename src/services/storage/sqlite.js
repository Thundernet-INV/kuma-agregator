<<<<<<< HEAD
import sqlite3 from 'sqlite3';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

let db = null;
const dataDir = path.join(__dirname, '../../../data');
const dbFile = path.join(dataDir, 'history.db');

export async function initSQLite() {
  if (db) return;
  
  if (!fs.existsSync(dataDir)) {
    fs.mkdirSync(dataDir, { recursive: true });
  }
  
  return new Promise((resolve, reject) => {
    db = new sqlite3.Database(dbFile, (err) => {
      if (err) {
        console.error('❌ Error abriendo base de datos:', err.message);
        reject(err);
        return;
      }
      
      console.log('✅ Base de datos SQLite lista');
      
      // Solo tabla history
      db.run(`
        CREATE TABLE IF NOT EXISTS history (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          monitorId TEXT NOT NULL,
          timestamp INTEGER NOT NULL,
          status TEXT NOT NULL,
          responseTime REAL,
          message TEXT,
          instance TEXT,
          createdAt DATETIME DEFAULT CURRENT_TIMESTAMP
        )
      `, (err) => {
        if (err) {
          console.error('❌ Error creando tabla:', err.message);
          reject(err);
        } else {
          // Índices esenciales
          db.run("CREATE INDEX IF NOT EXISTS idx_monitor_time ON history (monitorId, timestamp)");
          db.run("CREATE INDEX IF NOT EXISTS idx_timestamp ON history (timestamp)");
          db.run("CREATE INDEX IF NOT EXISTS idx_instance ON history (instance)");
          console.log('✅ Tabla history e índices listos');
          resolve();
        }
      });
    });
  });
}

export async function insertHistory(event) {
  if (!db) await initSQLite();
  
  return new Promise((resolve, reject) => {
    const { monitorId, timestamp, status, responseTime, message } = event;
    const instance = monitorId.includes('_') ? monitorId.split('_')[0] : 'unknown';
    
    db.run(
      `INSERT INTO history (monitorId, timestamp, status, responseTime, message, instance) 
       VALUES (?, ?, ?, ?, ?, ?)`,
      [monitorId, timestamp, status, responseTime, message, instance],
      function(err) {
        if (err) {
          console.error('❌ Error insertando:', err.message);
          reject(err);
        } else {
          resolve({ id: this.lastID });
        }
=======
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

    db.run(`CREATE INDEX IF NOT EXISTS idx_history_monitor_time ON monitor_history (monitorId, timestamp);`);
  });

  return db;
}

export function insertHistory(event) {
  return new Promise((resolve, reject) => {
    const { monitorId, timestamp, status, responseTime = null, message = null } = event;
    db.run(
      `INSERT INTO monitor_history (monitorId, timestamp, status, responseTime, message)
       VALUES (?, ?, ?, ?, ?)`,
      [monitorId, timestamp, status, responseTime, message],
      function (err) {
        if (err) return reject(err);
        resolve({ id: this.lastID });
>>>>>>> 0e1ae5e (ROLLBACK)
      }
    );
  });
}

<<<<<<< HEAD
export async function getHistory(params) {
  if (!db) await initSQLite();
  
  return new Promise((resolve, reject) => {
    const { monitorId, from, to, limit = 1000 } = params || {};
    
    let query = "SELECT * FROM history";
    const conditions = [];
    const values = [];
    
    if (monitorId) {
      conditions.push("monitorId = ?");
      values.push(monitorId);
    }
    if (from) {
      conditions.push("timestamp >= ?");
      values.push(from);
    }
    if (to) {
      conditions.push("timestamp <= ?");
      values.push(to);
    }
    
    if (conditions.length > 0) {
      query += " WHERE " + conditions.join(" AND ");
    }
    
    query += " ORDER BY timestamp DESC LIMIT ?";
    values.push(limit);
    
    db.all(query, values, (err, rows) => {
      if (err) reject(err);
      else resolve(rows);
    });
  });
}

export async function getHistoryAgg(params) {
  if (!db) await initSQLite();
  
  const { monitorId, from, to, bucketMs = 60000 } = params;
  
  return new Promise((resolve, reject) => {
    db.all(
      `SELECT 
        CAST((timestamp / ?) * ? AS INTEGER) AS bucket,
        AVG(CASE WHEN status = 'up' THEN 1.0 ELSE 0.0 END) as avgStatus,
        AVG(responseTime) as avgResponseTime,
        COUNT(*) as count
       FROM history 
       WHERE monitorId = ? 
         AND timestamp >= ? 
         AND timestamp <= ?
       GROUP BY bucket
       ORDER BY bucket ASC`,
      [bucketMs, bucketMs, monitorId, from, to],
      (err, rows) => {
        if (err) {
          console.error('Error en getHistoryAgg:', err);
          resolve([]);
        } else {
          resolve(rows);
        }
=======
export function getHistory({ monitorId, from, to, limit = 1000, offset = 0 }) {
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
>>>>>>> 0e1ae5e (ROLLBACK)
      }
    );
  });
}

<<<<<<< HEAD
export async function getAvailableMonitors() {
  if (!db) await initSQLite();
  
  return new Promise((resolve, reject) => {
    db.all(
      `SELECT 
        monitorId,
        COUNT(*) as totalChecks,
        MAX(timestamp) as lastCheck,
        MIN(timestamp) as firstCheck,
        AVG(CASE WHEN status = 'up' THEN 1.0 ELSE 0.0 END) * 100 as uptimePercent
       FROM history 
       GROUP BY monitorId
       ORDER BY lastCheck DESC`,
      [],
      (err, rows) => {
        if (err) {
          console.error('Error getting monitors:', err);
          resolve([]);
        } else {
          // Agregar instancia extraída
          const enhanced = rows.map(row => ({
            ...row,
            instance: row.monitorId.includes('_') ? row.monitorId.split('_')[0] : 'unknown'
          }));
          resolve(enhanced);
        }
      }
    );
  });
}

export async function getMonitorsByInstance(instanceName) {
  if (!db) await initSQLite();
  
  return new Promise((resolve, reject) => {
    db.all(
      `SELECT 
        monitorId,
        COUNT(*) as totalChecks,
        AVG(CASE WHEN status = 'up' THEN 1.0 ELSE 0.0 END) * 100 as uptimePercent,
        AVG(responseTime) as avgResponseTime
       FROM history 
       WHERE instance = ?
       GROUP BY monitorId
       ORDER BY monitorId ASC`,
      [instanceName],
      (err, rows) => {
        if (err) {
          console.error('Error getting monitors by instance:', err);
          resolve([]);
        } else {
          resolve(rows);
        }
      }
    );
  });
}

export async function getStats() {
  if (!db) await initSQLite();
  
  return new Promise((resolve, reject) => {
    db.get(
      `SELECT 
        COUNT(DISTINCT monitorId) as totalMonitors,
        COUNT(*) as totalRecords,
        MIN(timestamp) as earliestRecord,
        MAX(timestamp) as latestRecord
       FROM history`,
      [],
      (err, row) => {
        if (err) {
          console.error('Error getting stats:', err);
          resolve({ totalMonitors: 0, totalRecords: 0 });
        } else {
          resolve(row || { totalMonitors: 0, totalRecords: 0 });
        }
=======
export function getHistoryAgg({ monitorId, from, to, bucketMs = 60000 }) {
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
>>>>>>> 0e1ae5e (ROLLBACK)
      }
    );
  });
}

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
      }
    );
  });
}

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
      }
    );
  });
}

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
      }
    );
  });
}

// src/services/storage/sqlite.js
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
    
    // Crear tablas
    await db.exec(`
        CREATE TABLE IF NOT EXISTS monitor_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            monitorId TEXT NOT NULL,
            timestamp INTEGER NOT NULL,
            status TEXT NOT NULL,
            responseTime REAL,
            message TEXT,
            instance TEXT
        );
        
        CREATE INDEX IF NOT EXISTS idx_monitor_time 
        ON monitor_history(monitorId, timestamp);
        
        CREATE INDEX IF NOT EXISTS idx_timestamp 
        ON monitor_history(timestamp);
        
        CREATE INDEX IF NOT EXISTS idx_instance 
        ON monitor_history(instance);
    `);
    
    console.log('[SQLite] Base de datos inicializada para historial');
}

export async function insertHistory(event) {
    if (!db) await initSQLite();
    
    const { monitorId, timestamp, status, responseTime = null, message = null } = event;
    const instance = monitorId.includes('_') ? monitorId.split('_')[0] : 'unknown';
    
    const result = await db.run(
        `INSERT INTO monitor_history (monitorId, timestamp, status, responseTime, message, instance)
         VALUES (?, ?, ?, ?, ?, ?)`,
        [monitorId, timestamp, status, responseTime, message, instance]
    );
    
    return { id: result.lastID };
}

export async function getHistory(params) {
    if (!db) await initSQLite();
    
    const { monitorId, from, to, limit = 1000, offset = 0 } = params;
    
    return await db.all(
        `SELECT * FROM monitor_history
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
         FROM monitor_history
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
        avgResponseTime: row.avgResponseTime || 0,
        count: row.count
    }));
}

export async function getAvailableMonitors() {
    if (!db) await initSQLite();
    
    return await db.all(
        `SELECT 
            monitorId,
            instance,
            COUNT(*) as totalChecks,
            MAX(timestamp) as lastCheck,
            MIN(timestamp) as firstCheck
         FROM monitor_history
         GROUP BY monitorId, instance
         ORDER BY lastCheck DESC`
    );
}

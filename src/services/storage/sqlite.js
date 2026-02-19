// src/services/storage/sqlite.js - VERSIÓN CORREGIDA
import sqlite3 from 'sqlite3';
import path from 'path';
import { fileURLToPath } from 'url';
import fs from 'fs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

let db = null;

// Función para abrir la base de datos
async function openDatabase() {
    return new Promise((resolve, reject) => {
        const dbPath = path.join(__dirname, '../../../data/history.db');
        const database = new sqlite3.Database(dbPath, (err) => {
            if (err) {
                reject(err);
            } else {
                resolve(database);
            }
        });
    });
}

export async function initSQLite() {
    if (db) return db;
    
    try {
        const dataDir = path.join(__dirname, '../../../data');
        if (!fs.existsSync(dataDir)) {
            fs.mkdirSync(dataDir, { recursive: true });
        }
        
        db = await openDatabase();
        console.log('[SQLite] ✅ Base de datos inicializada');
        
        // Crear tablas si no existen
        await runQuery(`
            CREATE TABLE IF NOT EXISTS monitor_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                monitorId TEXT NOT NULL,
                timestamp INTEGER NOT NULL,
                status TEXT NOT NULL,
                responseTime REAL,
                message TEXT,
                instance TEXT
            )
        `);
        
        await runQuery(`
            CREATE TABLE IF NOT EXISTS active_monitors (
                monitorId TEXT PRIMARY KEY,
                instance TEXT NOT NULL,
                lastSeen INTEGER NOT NULL,
                monitorName TEXT,
                firstSeen INTEGER NOT NULL
            )
        `);
        
        // Tablas de combustible
        await runQuery(`
            CREATE TABLE IF NOT EXISTS plantas_combustible_config (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                nombre_monitor TEXT NOT NULL UNIQUE,
                sede TEXT NOT NULL,
                modelo TEXT,
                consumo_lh REAL NOT NULL,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
        `);
        
        await runQuery(`
            CREATE TABLE IF NOT EXISTS planta_eventos (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                nombre_monitor TEXT NOT NULL,
                estado TEXT NOT NULL CHECK(estado IN ('UP', 'DOWN')),
                timestamp_inicio INTEGER NOT NULL,
                timestamp_fin INTEGER,
                duracion_segundos INTEGER,
                consumo_litros REAL,
                FOREIGN KEY (nombre_monitor) REFERENCES plantas_combustible_config(nombre_monitor)
            )
        `);
        
        await runQuery(`
            CREATE INDEX IF NOT EXISTS idx_planta_eventos_monitor ON planta_eventos(nombre_monitor, timestamp_inicio)
        `);
        
        await runQuery(`
            CREATE INDEX IF NOT EXISTS idx_planta_eventos_activos ON planta_eventos(nombre_monitor) WHERE timestamp_fin IS NULL
        `);
        
        console.log('[SQLite] ✅ Tablas verificadas/creadas correctamente');
        
        return db;
    } catch (error) {
        console.error('[SQLite] ❌ Error crítico:', error);
        throw error;
    }
}

export async function ensureSQLite() {
    if (!db) {
        db = await initSQLite();
    }
    return db;
}

// Helper para ejecutar queries
export function runQuery(sql, params = []) {
    return new Promise((resolve, reject) => {
        db.run(sql, params, function(err) {
            if (err) reject(err);
            else resolve({ lastID: this.lastID, changes: this.changes });
        });
    });
}

export function getQuery(sql, params = []) {
    return new Promise((resolve, reject) => {
        db.get(sql, params, (err, row) => {
            if (err) reject(err);
            else resolve(row);
        });
    });
}

export function allQuery(sql, params = []) {
    return new Promise((resolve, reject) => {
        db.all(sql, params, (err, rows) => {
            if (err) reject(err);
            else resolve(rows);
        });
    });
}

// ========== FUNCIONES EXISTENTES (adaptadas) ==========

export async function insertHistory(event) {
    await ensureSQLite();
    
    const { monitorId, timestamp, status, responseTime = null, message = null } = event;
    const instance = monitorId.includes('_') ? monitorId.split('_')[0] : 'unknown';
    const monitorName = monitorId.includes('_') ? monitorId.split('_').slice(1).join('_') : monitorId;
    
    try {
        const result = await runQuery(
            `INSERT INTO monitor_history (monitorId, timestamp, status, responseTime, message, instance)
             VALUES (?, ?, ?, ?, ?, ?)`,
            [monitorId, timestamp, status, responseTime, message, instance]
        );
        
        await runQuery(`
            INSERT INTO active_monitors (monitorId, instance, lastSeen, firstSeen, monitorName)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(monitorId) DO UPDATE SET
                lastSeen = excluded.lastSeen,
                instance = excluded.instance,
                monitorName = excluded.monitorName
        `, [monitorId, instance, timestamp, timestamp, monitorName]);
        
        return { id: result.lastID };
    } catch (error) {
        console.error('[SQLite] Error insertando:', error);
        throw error;
    }
}

export async function getHistory(params) {
    await ensureSQLite();
    const { monitorId, from, to, limit = 1000, offset = 0 } = params;
    return await allQuery(
        `SELECT * FROM monitor_history
         WHERE monitorId = ? AND timestamp >= ? AND timestamp <= ?
         ORDER BY timestamp DESC LIMIT ? OFFSET ?`,
        [monitorId, from, to, limit, offset]
    );
}

export async function getHistoryAgg(params) {
    await ensureSQLite();
    const { monitorId, from, to, bucketMs = 60000 } = params;
    
    const rows = await allQuery(
        `SELECT
            CAST((timestamp / ?) * ? AS INTEGER) AS bucket,
            AVG(CASE WHEN status = 'up' THEN 1 ELSE 0 END) as avgStatus,
            AVG(responseTime) as avgResponseTime,
            COUNT(*) as count
         FROM monitor_history
         WHERE monitorId = ? AND timestamp >= ? AND timestamp <= ?
         GROUP BY bucket ORDER BY bucket ASC`,
        [bucketMs, bucketMs, monitorId, from, to]
    );
    
    return rows.map(row => ({
        timestamp: row.bucket,
        avgStatus: row.avgStatus,
        avgResponseTime: row.avgResponseTime || 0,
        count: row.count
    }));
}

export default {
    ensureSQLite,
    insertHistory,
    getHistory,
    getHistoryAgg
};

// ========== EXPORTACIONES ADICIONALES ==========

export async function getAvailableMonitors() {
    await ensureSQLite();
    try {
        await cleanupInactiveMonitors(10);
        return await allQuery(`
            SELECT 
                am.monitorId,
                am.instance,
                am.lastSeen,
                am.firstSeen,
                am.monitorName,
                COUNT(h.id) as totalChecks,
                AVG(CASE WHEN h.status = 'up' THEN 1.0 ELSE 0.0 END) * 100 as uptimePercent,
                AVG(h.responseTime) as avgResponseTime
            FROM active_monitors am
            LEFT JOIN monitor_history h ON h.monitorId = am.monitorId 
                AND h.timestamp >= am.lastSeen - 86400000
            GROUP BY am.monitorId
            ORDER BY am.lastSeen DESC
        `);
    } catch (error) {
        console.error('[SQLite] Error obteniendo monitores:', error);
        return [];
    }
}

export async function getMonitorsByInstance(instanceName, hours = 24) {
    await ensureSQLite();
    try {
        const from = Date.now() - (hours * 60 * 60 * 1000);
        const to = Date.now();
        
        await cleanupInactiveMonitors(10);
        
        return await allQuery(`
            SELECT 
                am.monitorId,
                am.monitorName,
                am.lastSeen,
                COUNT(h.id) as totalChecks,
                AVG(CASE WHEN h.status = 'up' THEN 1.0 ELSE 0.0 END) * 100 as uptimePercent,
                AVG(h.responseTime) as avgResponseTime
            FROM active_monitors am
            LEFT JOIN monitor_history h ON h.monitorId = am.monitorId 
                AND h.timestamp >= ? 
                AND h.timestamp <= ?
            WHERE am.instance = ?
            GROUP BY am.monitorId
            ORDER BY am.lastSeen DESC
        `, [from, to, instanceName]);
    } catch (error) {
        console.error('[SQLite] Error obteniendo monitores por instancia:', error);
        return [];
    }
}

export async function cleanupInactiveMonitors(olderThanMinutes = 10) {
    await ensureSQLite();
    try {
        const threshold = Date.now() - (olderThanMinutes * 60 * 1000);
        
        const result = await runQuery(
            `DELETE FROM active_monitors WHERE lastSeen < ?`,
            [threshold]
        );
        
        if (result.changes > 0) {
            console.log(`[SQLite] 🧹 Limpieza: ${result.changes} monitores inactivos eliminados`);
        }
        
        return result.changes || 0;
    } catch (error) {
        console.error('[SQLite] Error en limpieza:', error);
        return 0;
    }
}

export async function markMonitorsInactive(activeMonitorIds) {
    await ensureSQLite();
    try {
        const threshold = Date.now() - (10 * 60 * 1000);
        
        if (activeMonitorIds && activeMonitorIds.length > 0) {
            const placeholders = activeMonitorIds.map(() => '?').join(',');
            const result = await runQuery(
                `DELETE FROM active_monitors 
                 WHERE lastSeen < ? 
                   AND monitorId NOT IN (${placeholders})`,
                [threshold, ...activeMonitorIds]
            );
            
            if (result.changes > 0) {
                console.log(`[SQLite] 🧹 Marcados ${result.changes} monitores como inactivos`);
            }
            return result.changes;
        }
        return 0;
    } catch (error) {
        console.error('[SQLite] Error marcando inactivos:', error);
        return 0;
    }
}

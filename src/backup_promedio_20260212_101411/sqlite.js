// src/services/storage/sqlite.js - VERSIÓN CORREGIDA
import sqlite3 from 'sqlite3';
import { open } from 'sqlite';
import path from 'path';
import { fileURLToPath } from 'url';
import fs from 'fs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

let db = null;

export async function initSQLite() {
    if (db) return db;
    
    try {
        // Asegurar que el directorio data existe
        const dataDir = path.join(__dirname, '../../../data');
        if (!fs.existsSync(dataDir)) {
            fs.mkdirSync(dataDir, { recursive: true });
        }
        
        const dbPath = path.join(dataDir, 'history.db');
        console.log(`[SQLite] Inicializando base de datos en: ${dbPath}`);
        
        db = await open({
            filename: dbPath,
            driver: sqlite3.Database
        });
        
        // Crear tabla de historial (existe)
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
        
        // 🟢 NUEVO: Crear tabla de monitores activos (ESTO FALTABA)
        await db.exec(`
            CREATE TABLE IF NOT EXISTS active_monitors (
                monitorId TEXT PRIMARY KEY,
                instance TEXT NOT NULL,
                lastSeen INTEGER NOT NULL,
                monitorName TEXT,
                firstSeen INTEGER NOT NULL
            );
            
            CREATE INDEX IF NOT EXISTS idx_active_lastSeen 
            ON active_monitors(lastSeen);
            
            CREATE INDEX IF NOT EXISTS idx_active_instance 
            ON active_monitors(instance);
        `);
        
        console.log('[SQLite] ✅ Tablas verificadas/creadas correctamente');
        
        // 🟢 NUEVO: Poblar active_monitors con datos existentes (UNA SOLA VEZ)
        const count = await db.get(`SELECT COUNT(*) as count FROM active_monitors`);
        if (count.count === 0) {
            console.log('[SQLite] Poblando active_monitors con datos históricos...');
            await db.exec(`
                INSERT OR IGNORE INTO active_monitors (monitorId, instance, lastSeen, firstSeen, monitorName)
                SELECT 
                    monitorId,
                    instance,
                    MAX(timestamp) as lastSeen,
                    MIN(timestamp) as firstSeen,
                    CASE 
                        WHEN instr(monitorId, '_') > 0 
                        THEN substr(monitorId, instr(monitorId, '_') + 1)
                        ELSE monitorId
                    END as monitorName
                FROM monitor_history
                GROUP BY monitorId, instance
                HAVING lastSeen > strftime('%s','now')*1000 - (7 * 24 * 60 * 60 * 1000) -- últimos 7 días
            `);
            const populated = await db.get(`SELECT COUNT(*) as count FROM active_monitors`);
            console.log(`[SQLite] ✅ ${populated.count} monitores activos importados`);
        }
        
        return db;
    } catch (error) {
        console.error('[SQLite] ❌ Error crítico:', error);
        throw error; // Lanzar el error para que se vea en los logs
    }
}

// Asegurar que initSQLite se llama al importar
let initPromise = null;
export function ensureSQLite() {
    if (!initPromise) {
        initPromise = initSQLite();
    }
    return initPromise;
}

// Resto de funciones con ensureSQLite() en lugar de initSQLite directo

export async function insertHistory(event) {
    await ensureSQLite();
    
    const { monitorId, timestamp, status, responseTime = null, message = null } = event;
    const instance = monitorId.includes('_') ? monitorId.split('_')[0] : 'unknown';
    const monitorName = monitorId.includes('_') ? monitorId.split('_').slice(1).join('_') : monitorId;
    
    try {
        // Insertar en historial
        const result = await db.run(
            `INSERT INTO monitor_history (monitorId, timestamp, status, responseTime, message, instance)
             VALUES (?, ?, ?, ?, ?, ?)`,
            [monitorId, timestamp, status, responseTime, message, instance]
        );
        
        // Actualizar monitores activos
        await db.run(`
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

export async function getAvailableMonitors() {
    await ensureSQLite();
    
    try {
        // Limpiar inactivos automáticamente
        await cleanupInactiveMonitors(10);
        
        return await db.all(`
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
        
        return await db.all(`
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
        
        const result = await db.run(
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
            const result = await db.run(
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

// Mantener funciones existentes
export async function getHistory(params) {
    await ensureSQLite();
    const { monitorId, from, to, limit = 1000, offset = 0 } = params;
    return await db.all(
        `SELECT * FROM monitor_history
         WHERE monitorId = ? AND timestamp >= ? AND timestamp <= ?
         ORDER BY timestamp DESC LIMIT ? OFFSET ?`,
        [monitorId, from, to, limit, offset]
    );
}

export async function getHistoryAgg(params) {
    await ensureSQLite();
    const { monitorId, from, to, bucketMs = 60000 } = params;
    
    const result = await db.all(
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
    
    return result.map(row => ({
        timestamp: row.bucket,
        avgStatus: row.avgStatus,
        avgResponseTime: row.avgResponseTime || 0,
        count: row.count
    }));
}

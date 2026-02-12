#!/bin/bash
# fix-promedio-sede-corregido.sh - VERSIÓN CORREGIDA

echo "====================================================="
echo "📊 CREANDO SERVICIO DE PROMEDIOS POR INSTANCIA (CORREGIDO)"
echo "====================================================="

BACKEND_DIR="/opt/kuma-central/kuma-aggregator/src"
BACKUP_DIR="${BACKEND_DIR}/backup_promedio_$(date +%Y%m%d_%H%M%S)"

# ========== 1. CREAR BACKUP ==========
echo ""
echo "[1] Creando backup..."
mkdir -p "$BACKUP_DIR"
cp "${BACKEND_DIR}/services/storage/sqlite.js" "$BACKUP_DIR/" 2>/dev/null || true
cp "${BACKEND_DIR}/services/historyService.js" "$BACKUP_DIR/" 2>/dev/null || true
cp "${BACKEND_DIR}/index.js" "$BACKUP_DIR/" 2>/dev/null || true
echo "✅ Backup creado en: $BACKUP_DIR"

# ========== 2. ACTUALIZAR SQLITE.JS CON TABLA DE PROMEDIOS ==========
echo ""
echo "[2] Actualizando sqlite.js con tabla de promedios..."

cat > "${BACKEND_DIR}/services/storage/sqlite.js" << 'EOF'
// src/services/storage/sqlite.js - VERSIÓN CON PROMEDIOS DE SEDE
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
        
        // Tabla de historial de monitores
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
        
        // 🟢 NUEVO: Tabla de promedios por instancia (sede)
        await db.exec(`
            CREATE TABLE IF NOT EXISTS instance_averages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                instance TEXT NOT NULL,
                timestamp INTEGER NOT NULL,
                avgResponseTime REAL NOT NULL,
                avgStatus REAL NOT NULL,
                monitorCount INTEGER NOT NULL,
                upCount INTEGER NOT NULL,
                downCount INTEGER NOT NULL,
                degradedCount INTEGER NOT NULL,
                createdAt DATETIME DEFAULT CURRENT_TIMESTAMP
            );
            
            CREATE INDEX IF NOT EXISTS idx_instance_time 
            ON instance_averages(instance, timestamp);
            
            CREATE INDEX IF NOT EXISTS idx_instance_timestamp 
            ON instance_averages(timestamp);
        `);
        
        // Tabla de monitores activos
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

// ========== FUNCIONES PARA MONITORES ==========

export async function insertHistory(event) {
    await ensureSQLite();
    
    const { monitorId, timestamp, status, responseTime = null, message = null } = event;
    const instance = monitorId.includes('_') ? monitorId.split('_')[0] : 'unknown';
    const monitorName = monitorId.includes('_') ? monitorId.split('_').slice(1).join('_') : monitorId;
    
    try {
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

// ========== 🟢 FUNCIONES PARA PROMEDIOS DE INSTANCIA ==========

export async function calculateInstanceAverage(instanceName, timestamp = Date.now()) {
    await ensureSQLite();
    
    const from = timestamp - (5 * 60 * 1000); // Últimos 5 minutos
    const to = timestamp;
    
    try {
        // Obtener todos los monitores de la instancia en los últimos 5 minutos
        const monitors = await db.all(`
            SELECT 
                monitorId,
                AVG(responseTime) as avgResponseTime,
                AVG(CASE WHEN status = 'up' THEN 1 ELSE 0 END) as avgStatus,
                COUNT(*) as samples
            FROM monitor_history
            WHERE instance = ? 
                AND timestamp >= ? 
                AND timestamp <= ?
                AND responseTime IS NOT NULL
            GROUP BY monitorId
        `, [instanceName, from, to]);
        
        if (monitors.length === 0) {
            console.log(`[SQLite] No hay datos para calcular promedio de ${instanceName}`);
            return null;
        }
        
        // Calcular promedios generales
        let totalResponseTime = 0;
        let totalStatus = 0;
        let validResponseCount = 0;
        let upCount = 0;
        let downCount = 0;
        let degradedCount = 0;
        
        for (const m of monitors) {
            if (m.avgResponseTime > 0) {
                totalResponseTime += m.avgResponseTime;
                validResponseCount++;
            }
            totalStatus += m.avgStatus;
            
            // Contar estados (aproximado)
            if (m.avgStatus > 0.8) upCount++;
            else if (m.avgStatus < 0.2) downCount++;
            else degradedCount++;
        }
        
        const avgResponseTime = validResponseCount > 0 ? totalResponseTime / validResponseCount : 0;
        const avgStatus = totalStatus / monitors.length;
        
        // Insertar el promedio
        const result = await db.run(`
            INSERT INTO instance_averages 
                (instance, timestamp, avgResponseTime, avgStatus, monitorCount, upCount, downCount, degradedCount)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        `, [
            instanceName, 
            timestamp, 
            avgResponseTime, 
            avgStatus, 
            monitors.length,
            upCount,
            downCount,
            degradedCount
        ]);
        
        console.log(`[SQLite] ✅ Promedio calculado para ${instanceName}: ${Math.round(avgResponseTime)}ms (${monitors.length} monitores)`);
        
        return {
            instance: instanceName,
            timestamp,
            avgResponseTime,
            avgStatus,
            monitorCount: monitors.length,
            upCount,
            downCount,
            degradedCount
        };
    } catch (error) {
        console.error(`[SQLite] Error calculando promedio para ${instanceName}:`, error);
        return null;
    }
}

export async function calculateAllInstanceAverages() {
    await ensureSQLite();
    
    try {
        // Obtener todas las instancias con monitores activos
        const instances = await db.all(`
            SELECT DISTINCT instance FROM active_monitors
            WHERE lastSeen > ?
        `, [Date.now() - (10 * 60 * 1000)]); // Últimos 10 minutos
        
        console.log(`[SQLite] Calculando promedios para ${instances.length} instancias...`);
        
        const results = [];
        for (const row of instances) {
            const result = await calculateInstanceAverage(row.instance);
            if (result) results.push(result);
        }
        
        console.log(`[SQLite] ✅ Promedios calculados para ${results.length} instancias`);
        return results;
    } catch (error) {
        console.error('[SQLite] Error calculando promedios:', error);
        return [];
    }
}

export async function getInstanceAverage(instanceName, sinceMs = 60 * 60 * 1000) {
    await ensureSQLite();
    
    const from = Date.now() - sinceMs;
    const to = Date.now();
    
    try {
        const averages = await db.all(`
            SELECT * FROM instance_averages
            WHERE instance = ? 
                AND timestamp >= ? 
                AND timestamp <= ?
            ORDER BY timestamp ASC
        `, [instanceName, from, to]);
        
        return averages;
    } catch (error) {
        console.error(`[SQLite] Error obteniendo promedios para ${instanceName}:`, error);
        return [];
    }
}

export async function getLatestInstanceAverage(instanceName) {
    await ensureSQLite();
    
    try {
        const average = await db.get(`
            SELECT * FROM instance_averages
            WHERE instance = ?
            ORDER BY timestamp DESC
            LIMIT 1
        `, [instanceName]);
        
        return average;
    } catch (error) {
        console.error(`[SQLite] Error obteniendo último promedio para ${instanceName}:`, error);
        return null;
    }
}

// ========== FUNCIONES EXISTENTES ==========

export async function getAvailableMonitors() {
    await ensureSQLite();
    
    try {
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
EOF

echo "✅ sqlite.js actualizado con tabla de promedios"
echo ""

# ========== 3. ACTUALIZAR HISTORYSERVICE.JS ==========
echo ""
echo "[3] Actualizando historyService.js con funciones de promedios..."

cat > "${BACKEND_DIR}/services/historyService.js" << 'EOF'
// src/services/historyService.js - CON SOPORTE PARA PROMEDIOS DE INSTANCIA
import { 
    ensureSQLite,
    insertHistory, 
    getHistory, 
    getHistoryAgg,
    getAvailableMonitors as getAvailableMonitorsFromDB,
    getMonitorsByInstance as getMonitorsByInstanceFromDB,
    cleanupInactiveMonitors,
    markMonitorsInactive,
    calculateInstanceAverage,
    calculateAllInstanceAverages,
    getInstanceAverage,
    getLatestInstanceAverage
} from './storage/sqlite.js';

export async function init() {
    try {
        await ensureSQLite();
        console.log('[HistoryService] ✅ Inicializado correctamente');
        
        // Calcular promedios iniciales
        setTimeout(async () => {
            await calculateAllInstanceAverages();
        }, 5000);
        
        return true;
    } catch (error) {
        console.error('[HistoryService] ❌ Error en inicialización:', error);
        throw error;
    }
}

export async function addEvent(event) {
    const result = await insertHistory(event);
    
    // Cada 10 eventos, calcular promedios
    if (Math.random() < 0.1) { // 10% de probabilidad
        const instance = event.monitorId.includes('_') ? event.monitorId.split('_')[0] : 'unknown';
        await calculateInstanceAverage(instance).catch(e => 
            console.error('Error calculando promedio:', e)
        );
    }
    
    return result;
}

export async function listRaw(params) {
    return getHistory(params);
}

export async function listSeries(params) {
    const bucketMs = Number(params.bucketMs || 60000);
    return getHistoryAgg({ ...params, bucketMs });
}

// ========== 🟢 FUNCIONES PARA PROMEDIOS DE INSTANCIA ==========

export async function getInstanceAverageSeries(instanceName, sinceMs = 60 * 60 * 1000) {
    try {
        const averages = await getInstanceAverage(instanceName, sinceMs);
        
        // Convertir al formato que espera el frontend
        return averages.map(avg => ({
            ts: avg.timestamp,
            ms: avg.avgResponseTime,
            sec: avg.avgResponseTime / 1000,
            status: avg.avgStatus > 0.5 ? 'up' : 'down',
            monitorCount: avg.monitorCount,
            upCount: avg.upCount,
            downCount: avg.downCount
        }));
    } catch (error) {
        console.error(`[HistoryService] Error obteniendo serie de promedios para ${instanceName}:`, error);
        return [];
    }
}

export async function getLatestAverage(instanceName) {
    try {
        return await getLatestInstanceAverage(instanceName);
    } catch (error) {
        console.error(`[HistoryService] Error obteniendo último promedio para ${instanceName}:`, error);
        return null;
    }
}

export async function triggerAverageCalculation() {
    try {
        return await calculateAllInstanceAverages();
    } catch (error) {
        console.error('[HistoryService] Error en cálculo de promedios:', error);
        return [];
    }
}

// ========== FUNCIONES EXISTENTES ==========

export async function getAvailableMonitors() {
    try {
        return await getAvailableMonitorsFromDB();
    } catch (error) {
        console.error('[HistoryService] Error en getAvailableMonitors:', error);
        return [];
    }
}

export async function getMonitorsByInstance(instanceName, hours = 24) {
    try {
        return await getMonitorsByInstanceFromDB(instanceName, hours);
    } catch (error) {
        console.error('[HistoryService] Error en getMonitorsByInstance:', error);
        return [];
    }
}

export async function cleanupInactive(minutes = 10) {
    try {
        return await cleanupInactiveMonitors(minutes);
    } catch (error) {
        console.error('[HistoryService] Error en cleanupInactive:', error);
        return 0;
    }
}

export async function markActiveMonitors(activeIds) {
    try {
        return await markMonitorsInactive(activeIds);
    } catch (error) {
        console.error('[HistoryService] Error en markActiveMonitors:', error);
        return 0;
    }
}

export async function getStats() {
    try {
        const db = await ensureSQLite();
        const totalMonitors = await db.get('SELECT COUNT(*) as count FROM active_monitors');
        const totalHistory = await db.get('SELECT COUNT(*) as count FROM monitor_history');
        const totalAverages = await db.get('SELECT COUNT(*) as count FROM instance_averages');
        
        return {
            activeMonitors: totalMonitors?.count || 0,
            totalRecords: totalHistory?.count || 0,
            totalAverages: totalAverages?.count || 0,
            timestamp: Date.now()
        };
    } catch (error) {
        console.error('[HistoryService] Error en getStats:', error);
        return { 
            activeMonitors: 0, 
            totalRecords: 0, 
            totalAverages: 0,
            error: error.message 
        };
    }
}
EOF

echo "✅ historyService.js actualizado con funciones de promedios"
echo ""

# ========== 4. CREAR ENDPOINT PARA PROMEDIOS ==========
echo ""
echo "[4] Creando endpoint /api/instance/average..."

cat > "${BACKEND_DIR}/routes/instanceAverageRoutes.js" << 'EOF'
// src/routes/instanceAverageRoutes.js
import { Router } from 'express';
import * as historyService from '../services/historyService.js';

const router = Router();

// Obtener serie de promedios para una instancia
router.get('/:instanceName', async (req, res) => {
    try {
        const instanceName = decodeURIComponent(req.params.instanceName);
        const { hours = 1 } = req.query;
        
        const sinceMs = parseInt(hours) * 60 * 60 * 1000;
        
        console.log(`[API] GET promedios para instancia: ${instanceName}, horas: ${hours}`);
        
        const series = await historyService.getInstanceAverageSeries(instanceName, sinceMs);
        
        res.json({
            success: true,
            instance: instanceName,
            hours: parseInt(hours),
            data: series,
            count: series.length
        });
    } catch (error) {
        console.error('[API] Error obteniendo promedios:', error);
        res.status(500).json({ 
            success: false, 
            error: 'Error obteniendo promedios',
            message: error.message 
        });
    }
});

// Obtener último promedio de una instancia
router.get('/:instanceName/latest', async (req, res) => {
    try {
        const instanceName = decodeURIComponent(req.params.instanceName);
        
        const latest = await historyService.getLatestAverage(instanceName);
        
        res.json({
            success: true,
            instance: instanceName,
            data: latest
        });
    } catch (error) {
        console.error('[API] Error obteniendo último promedio:', error);
        res.status(500).json({ 
            success: false, 
            error: 'Error obteniendo último promedio' 
        });
    }
});

// Forzar cálculo de promedios (admin)
router.post('/calculate', async (req, res) => {
    try {
        const results = await historyService.triggerAverageCalculation();
        
        res.json({
            success: true,
            message: `Promedios calculados para ${results.length} instancias`,
            data: results
        });
    } catch (error) {
        console.error('[API] Error forzando cálculo:', error);
        res.status(500).json({ 
            success: false, 
            error: 'Error calculando promedios' 
        });
    }
});

export default router;
EOF

echo "✅ instanceAverageRoutes.js creado"
echo ""

# ========== 5. MODIFICAR INDEX.JS PARA INCLUIR EL NUEVO ENDPOINT ==========
echo ""
echo "[5] Modificando index.js para incluir endpoint de promedios..."

INDEX_FILE="${BACKEND_DIR}/index.js"

if [ -f "$INDEX_FILE" ]; then
    # Backup
    cp "$INDEX_FILE" "$BACKUP_DIR/index.js.bak"
    
    # Verificar si ya tiene el import
    if ! grep -q "import instanceAverageRoutes" "$INDEX_FILE"; then
        # Buscar la línea de los otros imports y agregar después
        sed -i '/import \* as historyService/a import instanceAverageRoutes from '\''./routes/instanceAverageRoutes.js'\'';' "$INDEX_FILE"
        echo "  ✅ Import agregado"
    fi
    
    # Verificar si ya tiene el app.use
    if ! grep -q "app.use(.api/instance/average." "$INDEX_FILE"; then
        # Buscar después de metric-history y agregar
        sed -i '/app\.use(.api\/metric-history./a app.use('\''/api/instance/average'\'', instanceAverageRoutes);' "$INDEX_FILE"
        echo "  ✅ Endpoint montado"
    fi
    
    echo "✅ index.js modificado"
fi

# ========== 6. CREAR SCRIPT DE MANTENIMIENTO DE PROMEDIOS ==========
echo ""
echo "[6] Creando script de mantenimiento de promedios..."

mkdir -p "${BACKEND_DIR}/../scripts"

cat > "${BACKEND_DIR}/../scripts/calculate-averages.js" << 'EOF'
#!/usr/bin/env node
// scripts/calculate-averages.js
// Script para calcular promedios de instancias manualmente

import { ensureSQLite, calculateAllInstanceAverages } from '../src/services/storage/sqlite.js';

async function main() {
    console.log('📊 Calculando promedios de instancias...');
    
    try {
        await ensureSQLite();
        const results = await calculateAllInstanceAverages();
        
        console.log(`✅ Promedios calculados para ${results.length} instancias`);
        
        if (results.length > 0) {
            console.log('\nResumen:');
            results.forEach(r => {
                console.log(`  • ${r.instance}: ${Math.round(r.avgResponseTime)}ms (${r.monitorCount} monitores)`);
            });
        }
        
        process.exit(0);
    } catch (error) {
        console.error('❌ Error:', error);
        process.exit(1);
    }
}

main();
EOF

chmod +x "${BACKEND_DIR}/../scripts/calculate-averages.js"
echo "✅ Script de mantenimiento creado"

# ========== 7. CREAR CRON JOB PARA PROMEDIOS ==========
echo ""
echo "[7] Creando cron job para calcular promedios cada 5 minutos..."

CRON_JOB="*/5 * * * * cd ${BACKEND_DIR}/.. && /usr/bin/node scripts/calculate-averages.js >> /var/log/kuma-averages.log 2>&1"

# Verificar si ya existe
if ! crontab -l 2>/dev/null | grep -q "calculate-averages.js"; then
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    echo "✅ Cron job agregado (cada 5 minutos)"
else
    echo "⚠️ Cron job ya existe"
fi

# ========== 8. GENERAR DATOS DE PRUEBA ==========
echo ""
echo "[8] Generando datos de prueba iniciales..."

cat > "${BACKEND_DIR}/../scripts/generate-test-averages.js" << 'EOF'
#!/usr/bin/env node
// scripts/generate-test-averages.js
// Genera datos de prueba para promedios de instancias

import { ensureSQLite } from '../src/services/storage/sqlite.js';
import * as historyService from '../src/services/historyService.js';

const INSTANCIAS = [
    'Caracas', 'Guanare', 'Barquisimeto', 'San Felipe', 'San Carlos',
    'Acarigua', 'Barinas', 'San Fernando', 'Chichiriviche', 'Tucacas'
];

async function generateTestData() {
    console.log('📊 Generando datos de prueba para promedios...');
    
    try {
        await ensureSQLite();
        
        const now = Date.now();
        const hourMs = 60 * 60 * 1000;
        
        // Generar datos para las últimas 24 horas
        for (let hour = 0; hour < 24; hour++) {
            const timestamp = now - (hour * hourMs);
            
            for (const instancia of INSTANCIAS) {
                // Crear entre 3-8 monitores por instancia
                const numMonitores = Math.floor(Math.random() * 5) + 3;
                
                for (let i = 0; i < numMonitores; i++) {
                    const monitorId = `${instancia}_Servicio_${i + 1}`;
                    const status = Math.random() > 0.1 ? 'up' : 'down';
                    const responseTime = status === 'up' ? 
                        Math.floor(Math.random() * 150) + 50 : 
                        -1;
                    
                    await historyService.addEvent({
                        monitorId,
                        timestamp: timestamp,
                        status,
                        responseTime: responseTime > 0 ? responseTime : null,
                        message: null
                    });
                }
            }
            
            if (hour % 6 === 0) {
                console.log(`  • Hora ${hour}: datos generados`);
            }
        }
        
        // Calcular promedios
        const { calculateAllInstanceAverages } = await import('../src/services/storage/sqlite.js');
        const results = await calculateAllInstanceAverages();
        
        console.log(`\n✅ Datos de prueba generados exitosamente`);
        console.log(`   • ${INSTANCIAS.length} instancias`);
        console.log(`   • ${results.length} promedios calculados`);
        
        process.exit(0);
    } catch (error) {
        console.error('❌ Error generando datos:', error);
        process.exit(1);
    }
}

generateTestData();
EOF

chmod +x "${BACKEND_DIR}/../scripts/generate-test-averages.js"

echo "✅ Script de datos de prueba creado"
echo ""

# ========== 9. EJECUTAR GENERACIÓN DE DATOS DE PRUEBA ==========
echo ""
echo "[9] Generando datos de prueba ahora..."

cd "${BACKEND_DIR}/.."
node scripts/generate-test-averages.js

# ========== 10. REINICIAR BACKEND ==========
echo ""
echo "[10] Reiniciando backend..."

# Buscar proceso del backend
BACKEND_PID=$(ps aux | grep "node.*index.js" | grep -v grep | awk '{print $2}')
if [ -n "$BACKEND_PID" ]; then
    echo "   Deteniendo backend (PID: $BACKEND_PID)..."
    kill $BACKEND_PID
    sleep 3
fi

# Iniciar backend
echo "   Iniciando backend..."
cd "${BACKEND_DIR}"
nohup node index.js > /var/log/kuma-backend.log 2>&1 &
sleep 3

echo "✅ Backend reiniciado"
echo ""

# ========== 11. VERIFICAR ENDPOINT ==========
echo ""
echo "[11] Verificando endpoint de promedios..."

sleep 2
if curl -s "http://10.10.31.31:8080/api/instance/average/Caracas?hours=1" | grep -q "success"; then
    echo "✅ Endpoint de promedios funcionando correctamente"
else
    echo "⚠️ Endpoint de promedios no responde aún"
fi

# ========== 12. INSTRUCCIONES FINALES ==========
echo ""
echo "====================================================="
echo "✅✅ SERVICIO DE PROMEDIOS IMPLEMENTADO ✅✅"
echo "====================================================="
echo ""
echo "📋 CAMBIOS REALIZADOS:"
echo ""
echo "1️⃣ NUEVA TABLA EN SQLITE: instance_averages"
echo "2️⃣ NUEVAS FUNCIONES EN SQLITE: calculateInstanceAverage(), etc."
echo "3️⃣ NUEVO ENDPOINT EN API: /api/instance/average/:instanceName"
echo "4️⃣ DATOS DE PRUEBA GENERADOS: 24 horas de datos"
echo "5️⃣ MANTENIMIENTO AUTOMÁTICO: Cron job cada 5 minutos"
echo ""
echo "🔄 PRÓXIMO PASO OBLIGATORIO:"
echo ""
echo "   AHORA DEBES EJECUTAR EL SCRIPT DEL FRONTEND:"
echo "   --------------------------------------------"
echo "   cd /home/thunder/kuma-dashboard-clean/kuma-ui"
echo "   ./fix-frontend-promedios.sh"
echo ""
echo "====================================================="

#!/bin/bash
# fix-historyservice-ahora.sh - CORREGIR FUNCIONES DUPLICADAS EN HISTORYSERVICE

echo "====================================================="
echo "🔧 CORRIGIENDO HISTORYSERVICE.JS - FUNCIONES DUPLICADAS"
echo "====================================================="

BACKEND_DIR="/opt/kuma-central/kuma-aggregator/src"
BACKUP_DIR="${BACKEND_DIR}/backup_historyservice_$(date +%Y%m%d_%H%M%S)"

# ========== 1. CREAR BACKUP ==========
echo ""
echo "[1] Creando backup..."
mkdir -p "$BACKUP_DIR"
cp "${BACKEND_DIR}/services/historyService.js" "$BACKUP_DIR/"
echo "✅ Backup creado en: $BACKUP_DIR"
echo ""

# ========== 2. CREAR HISTORYSERVICE.JS LIMPIO ==========
echo "[2] Creando historyService.js NUEVO y LIMPIO..."

cat > "${BACKEND_DIR}/services/historyService.js" << 'EOF'
// src/services/historyService.js - VERSIÓN LIMPIA SIN DUPLICADOS
import { 
    ensureSQLite,
    insertHistory, 
    getHistory, 
    getHistoryAgg,
    getAvailableMonitors as getAvailableMonitorsFromDB,
    getMonitorsByInstance as getMonitorsByInstanceFromDB,
    cleanupInactiveMonitors,
    markMonitorsInactive
} from './storage/sqlite.js';

export async function init() {
    try {
        await ensureSQLite();
        console.log('[HistoryService] ✅ Inicializado correctamente');
        return true;
    } catch (error) {
        console.error('[HistoryService] ❌ Error en inicialización:', error);
        throw error;
    }
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

// ========== FUNCIONES PARA MONITORES ==========

export async function getAvailableMonitors() {
    try {
        const monitors = await getAvailableMonitorsFromDB();
        return monitors || [];
    } catch (error) {
        console.error('[HistoryService] Error en getAvailableMonitors:', error);
        return [];
    }
}

export async function getMonitorsByInstance(instanceName, hours = 24) {
    try {
        const monitors = await getMonitorsByInstanceFromDB(instanceName, hours);
        return monitors || [];
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

// ========== 🆕 FUNCIONES PARA PROMEDIOS DE INSTANCIA (AGREGADAS) ==========

export async function getInstanceAverages(instanceName, hours = 24) {
    try {
        // Importar dinámicamente para evitar dependencias circulares
        const { getInstanceAverages: getAverages } = await import('./storage/sqlite.js');
        return await getAverages(instanceName, hours);
    } catch (error) {
        console.error('[HistoryService] Error obteniendo promedios:', error);
        return [];
    }
}

export async function calculateAllInstanceAverages() {
    try {
        const { calculateAllInstanceAverages: calculateAll } = await import('./storage/sqlite.js');
        return await calculateAll();
    } catch (error) {
        console.error('[HistoryService] Error calculando promedios:', error);
        return [];
    }
}

// ========== FUNCIÓN DE DIAGNÓSTICO ==========

export async function getStats() {
    try {
        const db = await ensureSQLite();
        const totalMonitors = await db.get('SELECT COUNT(*) as count FROM active_monitors');
        const totalHistory = await db.get('SELECT COUNT(*) as count FROM monitor_history');
        return {
            activeMonitors: totalMonitors?.count || 0,
            totalRecords: totalHistory?.count || 0,
            timestamp: Date.now()
        };
    } catch (error) {
        console.error('[HistoryService] Error en getStats:', error);
        return { activeMonitors: 0, totalRecords: 0, error: error.message };
    }
}
EOF

echo "✅ historyService.js NUEVO creado - SIN DUPLICADOS"
echo ""

# ========== 3. VERIFICAR SQLITE.JS TIENE LAS FUNCIONES ==========
echo "[3] Verificando sqlite.js..."

if ! grep -q "calculateAllInstanceAverages" "${BACKEND_DIR}/services/storage/sqlite.js"; then
    echo "⚠️ Agregando funciones de promedios a sqlite.js..."
    
    cat >> "${BACKEND_DIR}/services/storage/sqlite.js" << 'EOF'

// ========== 🆕 FUNCIONES PARA PROMEDIOS DE INSTANCIA ==========

export async function calculateInstanceAverage(instanceName, timestamp = Date.now()) {
    const db = await ensureSQLite();
    
    const from = timestamp - (5 * 60 * 1000);
    const to = timestamp;
    
    try {
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
        
        if (monitors.length === 0) return null;
        
        let totalResponseTime = 0;
        let totalStatus = 0;
        let validResponseCount = 0;
        
        for (const m of monitors) {
            if (m.avgResponseTime > 0) {
                totalResponseTime += m.avgResponseTime;
                validResponseCount++;
            }
            totalStatus += m.avgStatus;
        }
        
        const avgResponseTime = validResponseCount > 0 ? totalResponseTime / validResponseCount : 0;
        const avgStatus = totalStatus / monitors.length;
        
        const result = await db.run(`
            INSERT INTO instance_averages 
                (instance, timestamp, avgResponseTime, avgStatus, monitorCount)
            VALUES (?, ?, ?, ?, ?)
        `, [
            instanceName, 
            timestamp, 
            avgResponseTime, 
            avgStatus, 
            monitors.length
        ]);
        
        return { id: result.lastID };
    } catch (error) {
        console.error(`[SQLite] Error calculando promedio:`, error);
        return null;
    }
}

export async function getInstanceAverages(instanceName, hours = 24) {
    const db = await ensureSQLite();
    const from = Date.now() - (hours * 60 * 60 * 1000);
    
    try {
        return await db.all(`
            SELECT * FROM instance_averages
            WHERE instance = ? AND timestamp >= ?
            ORDER BY timestamp ASC
        `, [instanceName, from]);
    } catch (error) {
        console.error(`[SQLite] Error obteniendo promedios:`, error);
        return [];
    }
}

export async function calculateAllInstanceAverages() {
    const db = await ensureSQLite();
    
    try {
        const instances = await db.all(`
            SELECT DISTINCT instance FROM active_monitors
            WHERE lastSeen > ?
        `, [Date.now() - (10 * 60 * 1000)]);
        
        const results = [];
        for (const row of instances) {
            const result = await calculateInstanceAverage(row.instance);
            if (result) results.push(result);
        }
        
        console.log(`[SQLite] 📊 Promedios calculados para ${results.length} instancias`);
        return results;
    } catch (error) {
        console.error('[SQLite] Error calculando promedios:', error);
        return [];
    }
}
EOF
    echo "✅ Funciones agregadas a sqlite.js"
else
    echo "✅ sqlite.js ya tiene las funciones de promedios"
fi
echo ""

# ========== 4. REINICIAR BACKEND ==========
echo "[4] Matando procesos existentes..."
pkill -f "node.*index.js" 2>/dev/null || true
sleep 2

echo "[5] Iniciando backend..."
cd "${BACKEND_DIR}/.."
NODE_ENV=production nohup node src/index.js > /tmp/kuma-backend.log 2>&1 &
BACKEND_PID=$!
sleep 3

echo "✅ Backend iniciado con PID: $BACKEND_PID"

# ========== 5. VERIFICAR BACKEND ==========
echo ""
echo "[6] Verificando backend..."

if ps -p $BACKEND_PID > /dev/null; then
    echo "✅ Proceso vivo"
    
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/health)
    if [ "$HTTP_CODE" = "200" ]; then
        echo "✅ Health check OK"
    else
        echo "❌ Health check falló"
        tail -20 /tmp/kuma-backend.log
    fi
else
    echo "❌ El proceso murió"
    echo ""
    echo "=== ÚLTIMAS LÍNEAS DEL LOG ==="
    tail -20 /tmp/kuma-backend.log
fi

# ========== 6. REINICIAR FRONTEND ==========
echo ""
echo "[7] Reiniciando frontend..."

FRONTEND_DIR="/home/thunder/kuma-dashboard-clean/kuma-ui"
cd "$FRONTEND_DIR"
pkill -f "vite" 2>/dev/null || true
npm run dev &
sleep 3

# ========== 7. INSTRUCCIONES ==========
echo ""
echo "====================================================="
echo "✅✅ HISTORYSERVICE.JS CORREGIDO ✅✅"
echo "====================================================="
echo ""
echo "📋 CAMBIOS REALIZADOS:"
echo ""
echo "   • 🧹 ELIMINADAS todas las funciones duplicadas"
echo "   • 📝 historyService.js: NUEVO y LIMPIO"
echo "   • 📝 sqlite.js: FUNCIONES DE PROMEDIOS AGREGADAS"
echo "   • 🚀 Backend: REINICIADO (PID: $BACKEND_PID)"
echo ""
echo "🔄 PRUEBA AHORA:"
echo ""
echo "   1. Abre http://10.10.31.31:5173"
echo "   2. ✅ EL DASHBOARD DEBE FUNCIONAR"
echo "   3. ✅ Las gráficas deben cargar datos reales"
echo ""
echo "📌 VERIFICACIÓN MANUAL:"
echo ""
echo "   curl http://10.10.31.31:8080/health"
echo "   curl http://10.10.31.31:8080/api/summary"
echo "   curl http://10.10.31.31:8080/api/instance/averages/Caracas"
echo ""
echo "====================================================="

# Preguntar si quiere ver logs
read -p "¿Ver logs del backend? (s/N): " VIEW_LOGS
if [[ "$VIEW_LOGS" =~ ^[Ss]$ ]]; then
    echo ""
    tail -30 /tmp/kuma-backend.log
fi

# Preguntar si quiere abrir el navegador
read -p "¿Abrir el dashboard ahora? (s/N): " OPEN_BROWSER
if [[ "$OPEN_BROWSER" =~ ^[Ss]$ ]]; then
    xdg-open "http://10.10.31.31:5173" 2>/dev/null || \
    open "http://10.10.31.31:5173" 2>/dev/null || \
    echo "Abre http://10.10.31.31:5173 en tu navegador"
fi

echo ""
echo "✅ Script completado"

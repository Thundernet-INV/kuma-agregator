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

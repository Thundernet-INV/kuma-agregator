// src/services/historyService.js
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

// 🟢 FUNCIÓN PRINCIPAL PARA LA API - CORREGIDA
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

// 🟢 NUEVA: Función de diagnóstico
export async function getStats() {
    try {
        const db = await ensureSQLite();
        const totalMonitors = await db.get('SELECT COUNT(*) as count FROM active_monitors');
        const totalHistory = await db.get('SELECT COUNT(*) as count FROM monitor_history');
        return {
            activeMonitors: totalMonitors.count,
            totalRecords: totalHistory.count,
            timestamp: Date.now()
        };
    } catch (error) {
        console.error('[HistoryService] Error en getStats:', error);
        return { activeMonitors: 0, totalRecords: 0, error: error.message };
    }
}

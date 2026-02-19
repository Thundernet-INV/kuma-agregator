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

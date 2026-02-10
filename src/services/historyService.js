<<<<<<< HEAD
import { initSQLite, insertHistory, getHistory, getHistoryAgg, getAvailableMonitors, getMonitorsByInstance, getStats } from './storage/sqlite.js';
=======
import { initSQLite, insertHistory, getHistory, getHistoryAgg } from './storage/sqlite.js';
>>>>>>> 0e1ae5e (ROLLBACK)

export function init() {
  initSQLite();
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
<<<<<<< HEAD

// Nueva función para obtener histórico por monitor
export async function getMonitorHistory(monitorName, hours = 24) {
  const from = Date.now() - (hours * 60 * 60 * 1000);
  const to = Date.now();
  const bucketMs = 5 * 60 * 1000;
  
  return await getHistoryAgg({
    monitorId: monitorName,
    from,
    to,
    bucketMs
  });
}

// Función para obtener monitores disponibles
export async function getAvailableMonitorsList() {
  return await getAvailableMonitors();
}

// Función para obtener monitores por instancia
export async function getMonitorsByInstanceList(instanceName) {
  return await getMonitorsByInstance(instanceName);
}

// Función para obtener estadísticas (ARREGLADA)
export async function getStatsData() {
  try {
    const stats = await getStats();
    return {
      totalMonitors: stats?.totalMonitors || 0,
      totalRecords: stats?.totalRecords || 0,
      earliestRecord: stats?.earliestRecord || 0,
      latestRecord: stats?.latestRecord || 0,
      timestamp: Date.now()
    };
  } catch (error) {
    console.error('Error getting stats:', error);
    return {
      totalMonitors: 0,
      totalRecords: 0,
      earliestRecord: 0,
      latestRecord: 0,
      timestamp: Date.now()
    };
  }
}

// Función helper para normalizar nombres
export function normalizeMonitorName(name) {
  if (!name) return '';
  return name.replace(/\s+/g, '_');
}
=======
>>>>>>> 0e1ae5e (ROLLBACK)

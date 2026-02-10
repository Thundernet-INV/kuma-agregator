import { Router } from 'express';
import * as historyService from '../services/historyService.js';

const router = Router();

// Obtener monitores por instancia
router.get('/instance/:instanceName', async (req, res) => {
  try {
    const instanceName = decodeURIComponent(req.params.instanceName);
    
    console.log(`📋 Solicitando monitores para instancia: "${instanceName}"`);
    
    // Obtener monitores de esta instancia
    const monitors = await historyService.getMonitorsByInstanceList(instanceName);
    
    // Obtener estadísticas para cada monitor
    const monitorsWithHistory = await Promise.all(
      monitors.map(async (monitor) => {
        try {
          const history = await historyService.getMonitorHistory(monitor.name, 1); // Última hora
          const lastPoint = history[history.length - 1] || {};
          
          return {
            ...monitor,
            lastStatus: lastPoint.avgStatus > 0.5 ? 'up' : 'down',
            lastResponseTime: lastPoint.avgResponseTime || 0,
            lastUpdate: lastPoint.timestamp || Date.now(),
            dataPoints: history.length
          };
        } catch (error) {
          console.error(`Error obteniendo historial para ${monitor.name}:`, error);
          return {
            ...monitor,
            lastStatus: 'unknown',
            lastResponseTime: 0,
            lastUpdate: Date.now(),
            dataPoints: 0
          };
        }
      })
    );
    
    // Calcular estadísticas generales
    const upMonitors = monitorsWithHistory.filter(m => m.lastStatus === 'up').length;
    const downMonitors = monitorsWithHistory.filter(m => m.lastStatus === 'down').length;
    const totalMonitors = monitorsWithHistory.length;
    
    res.json({
      success: true,
      instanceName,
      stats: {
        total: totalMonitors,
        up: upMonitors,
        down: downMonitors,
        uptime: totalMonitors > 0 ? ((upMonitors / totalMonitors) * 100).toFixed(2) : 0
      },
      monitors: monitorsWithHistory,
      count: totalMonitors,
      timestamp: new Date().toISOString()
    });
    
  } catch (error) {
    console.error('❌ Error fetching instance monitors:', error);
    res.status(500).json({ 
      success: false,
      error: 'Internal server error',
      message: error.message
    });
  }
});

// Obtener lista de instancias disponibles
router.get('/instances', async (req, res) => {
  try {
    // Esto dependerá de cómo almacenas las instancias
    // Por ahora devolveremos algunas estáticas o de un archivo
    const instances = [
      { name: 'Caracas', description: 'Centro de datos principal' },
      { name: 'Guanare', description: 'Centro de datos secundario' },
      { name: 'Maracaibo', description: 'Sucursal occidente' },
      { name: 'Valencia', description: 'Sucursal centro' }
    ];
    
    res.json({
      success: true,
      instances,
      count: instances.length
    });
    
  } catch (error) {
    console.error('❌ Error fetching instances:', error);
    res.status(500).json({ 
      success: false,
      error: 'Internal server error'
    });
  }
});

export default router;

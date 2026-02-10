import { Router } from 'express';
import * as historyService from '../services/historyService.js';

const router = Router();

// Obtener historial agrupado por monitor
router.get('/monitor/:monitorName', async (req, res) => {
  try {
    const monitorName = decodeURIComponent(req.params.monitorName);
    const { hours = 24, bucketMinutes = 5 } = req.query;
    
    console.log(`📊 Solicitando historial para: "${monitorName}" (${hours}h)`);
    
    const from = Date.now() - (parseInt(hours) * 60 * 60 * 1000);
    const to = Date.now();
    
    const series = await historyService.listSeries({
      monitorId: monitorName,
      from: from,
      to: to,
      bucketMs: parseInt(bucketMinutes) * 60 * 1000
    });
    
    console.log(`✅ Historial obtenido: ${series.length} puntos`);
    
    res.json({
      success: true,
      monitorName,
      data: series.map(item => ({
        ts: item.timestamp,
        ms: item.avgResponseTime || 0,
        status: item.avgStatus > 0.5 ? 'up' : 'down'
      }))
    });
  } catch (error) {
    console.error('❌ Error fetching monitor history:', error);
    res.status(500).json({ 
      success: false,
      error: 'Internal server error'
    });
  }
});

// Obtener lista de monitors disponibles
router.get('/monitors', async (req, res) => {
  try {
    const monitors = await historyService.getAvailableMonitorsList();
    
    console.log(`📋 Enviando lista de ${monitors.length} monitores`);
    
    res.json({
      success: true,
      monitors,
      count: monitors.length
    });
  } catch (error) {
    console.error('❌ Error fetching monitors:', error);
    res.status(500).json({ 
      success: false,
      error: 'Internal server error' 
    });
  }
});

// Endpoint simple de salud
router.get('/health', (req, res) => {
  res.json({
    success: true,
    service: 'metric-history',
    timestamp: new Date().toISOString()
  });
});

export default router;

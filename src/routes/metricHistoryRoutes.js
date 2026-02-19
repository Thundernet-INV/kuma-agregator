// src/routes/metricHistoryRoutes.js
import { Router } from 'express';
import * as historyService from '../services/historyService.js';

const router = Router();

// 🟢 ENDPOINT PRINCIPAL - Obtener lista de monitores disponibles
router.get('/monitors', async (req, res) => {
    try {
        console.log('[API] GET /monitors - Solicitando lista de monitores');
        
        const monitors = await historyService.getAvailableMonitors();
        
        console.log(`[API] ✅ Enviando ${monitors.length} monitores`);
        
        res.json({
            success: true,
            monitors,
            count: monitors.length,
            timestamp: Date.now()
        });
    } catch (error) {
        console.error('[API] ❌ Error en /monitors:', error);
        res.status(500).json({ 
            success: false,
            error: 'Internal server error',
            message: error.message
        });
    }
});

// Obtener historial por monitor
router.get('/monitor/:monitorName', async (req, res) => {
    try {
        const monitorName = decodeURIComponent(req.params.monitorName);
        const { hours = 24, bucketMinutes = 5 } = req.query;
        
        console.log(`[API] GET /monitor/${monitorName} - ${hours}h`);
        
        const from = Date.now() - (parseInt(hours) * 60 * 60 * 1000);
        const to = Date.now();
        
        const series = await historyService.listSeries({
            monitorId: monitorName,
            from: from,
            to: to,
            bucketMs: parseInt(bucketMinutes) * 60 * 1000
        });
        
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
        console.error('[API] ❌ Error en monitor history:', error);
        res.status(500).json({ 
            success: false,
            error: 'Internal server error' 
        });
    }
});

// 🟢 NUEVO: Endpoint de estadísticas/diagnóstico
router.get('/stats', async (req, res) => {
    try {
        const stats = await historyService.getStats();
        res.json({
            success: true,
            ...stats
        });
    } catch (error) {
        res.status(500).json({ success: false, error: error.message });
    }
});

// Health check
router.get('/health', (req, res) => {
    res.json({
        success: true,
        service: 'metric-history',
        timestamp: new Date().toISOString()
    });
});

export default router;

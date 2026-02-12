// 🆕 NUEVO ENDPOINT - PROMEDIOS DE INSTANCIA
// NO modifica ningún endpoint existente

import { Router } from 'express';
import * as historyService from '../services/historyService.js';

const router = Router();

// Obtener promedios de una instancia
router.get('/:instanceName', async (req, res) => {
    try {
        const instanceName = decodeURIComponent(req.params.instanceName);
        const { hours = 24 } = req.query;
        
        const averages = await historyService.getInstanceAverages(instanceName, hours);
        
        res.json({
            success: true,
            instance: instanceName,
            hours: parseInt(hours),
            data: averages.map(a => ({
                ts: a.timestamp,
                avgResponseTime: a.avgResponseTime,
                avgStatus: a.avgStatus,
                monitorCount: a.monitorCount
            })),
            count: averages.length
        });
    } catch (error) {
        console.error('[API] Error:', error);
        res.status(500).json({ success: false, error: error.message });
    }
});

// Forzar cálculo de promedios
router.post('/calculate', async (req, res) => {
    try {
        const results = await historyService.calculateAllInstanceAverages();
        res.json({
            success: true,
            message: `Promedios calculados para ${results.length} instancias`,
            count: results.length
        });
    } catch (error) {
        res.status(500).json({ success: false, error: error.message });
    }
});

export default router;

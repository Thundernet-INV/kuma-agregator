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

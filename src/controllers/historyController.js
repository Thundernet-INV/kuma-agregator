// src/controllers/historyController.js
import { assertQuery } from '../utils/validate.js';
import * as historyService from '../services/historyService.js';

export async function getHistory(req, res) {
    try {
        const { monitorId, from, to } = req.query;
        const limit = Number(req.query.limit || 1000);
        const offset = Number(req.query.offset || 0);
        
        const errors = assertQuery({ monitorId, from, to, limit, offset });
        if (errors.length) return res.status(400).json({ errors });
        
        const rows = await historyService.listRaw({
            monitorId,
            from: Number(from),
            to: Number(to),
            limit,
            offset,
        });
        
        res.json({ data: rows, page: { limit, offset, count: rows.length } });
    } catch (err) {
        console.error('getHistory error:', err);
        res.status(500).json({ error: 'Internal Server Error' });
    }
}

export async function getSeries(req, res) {
    try {
        const { monitorId, from, to } = req.query;
        const bucketMs = Number(req.query.bucketMs || 60000);
        
        const errors = assertQuery({ monitorId, from, to, bucketMs });
        if (errors.length) return res.status(400).json({ errors });
        
        const series = await historyService.listSeries({
            monitorId,
            from: Number(from),
            to: Number(to),
            bucketMs,
        });
        
        res.json({ data: series, meta: { bucketMs } });
    } catch (err) {
        console.error('getSeries error:', err);
        res.status(500).json({ error: 'Internal Server Error' });
    }
}

// Endpoint para insertar eventos (útil para testing)
export async function postEvent(req, res) {
    try {
        const { monitorId, timestamp, status, responseTime = null, message = null } = req.body;
        
        const errors = [];
        if (!monitorId) errors.push('monitorId requerido');
        if (!timestamp || isNaN(Number(timestamp))) errors.push('timestamp inválido (epoch ms)');
        if (!['up', 'down', 'degraded'].includes(status)) {
            errors.push("status debe ser 'up', 'down' o 'degraded'");
        }
        
        if (errors.length) return res.status(400).json({ errors });
        
        const result = await historyService.addEvent({
            monitorId,
            timestamp: Number(timestamp),
            status,
            responseTime,
            message
        });
        
        res.status(201).json({ ok: true, id: result.id });
    } catch (err) {
        console.error('postEvent error:', err);
        res.status(500).json({ error: 'Internal Server Error' });
    }
}

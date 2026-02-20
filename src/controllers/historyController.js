// /opt/kuma-central/kuma-aggregator/src/controllers/historyController.js
import * as historyService from '../services/historyService.js';

export async function getHistory(req, res) {
  try {
    const { monitorId, from, to, limit = 1000 } = req.query;
    
    if (!monitorId || !from || !to) {
      return res.status(400).json({ 
        success: false, 
        error: 'Faltan parámetros: monitorId, from, to' 
      });
    }
    
    const history = await historyService.getHistory(
      monitorId, 
      Number(from), 
      Number(to), 
      Number(limit)
    );
    
    res.json({
      success: true,
      data: history,
      count: history.length,
      monitorId,
      from: Number(from),
      to: Number(to)
    });
  } catch (error) {
    console.error('getHistory error:', error);
    res.status(500).json({ success: false, error: error.message });
  }
}

export async function getSeries(req, res) {
  try {
    const { monitorId, from, to, bucketMs = 60000 } = req.query;
    
    if (!monitorId || !from || !to) {
      return res.status(400).json({ 
        success: false, 
        error: 'Faltan parámetros: monitorId, from, to' 
      });
    }
    
    console.log(`📊 getSeries: ${monitorId}, from=${from}, to=${to}, bucketMs=${bucketMs}`);
    
    // Obtener datos históricos
    const history = await historyService.getHistory(
      monitorId, 
      Number(from), 
      Number(to)
    );
    
    // Si no hay datos, devolver array vacío
    if (!history || history.length === 0) {
      return res.json({
        success: true,
        data: [],
        count: 0,
        monitorId,
        from: Number(from),
        to: Number(to),
        bucketMs: Number(bucketMs)
      });
    }
    
    // Agrupar por bucket de tiempo para suavizar la curva
    const buckets = new Map();
    const bucketSize = Number(bucketMs);
    
    history.forEach(item => {
      // Redondear timestamp al bucket más cercano
      const bucket = Math.floor(item.timestamp / bucketSize) * bucketSize;
      
      if (!buckets.has(bucket)) {
        buckets.set(bucket, {
          sum: 0,
          count: 0,
          timestamp: bucket,
          // Guardar el primer estado del bucket para referencia
          status: item.status
        });
      }
      
      const bucketData = buckets.get(bucket);
      if (item.responseTime && !isNaN(item.responseTime)) {
        bucketData.sum += Number(item.responseTime);
        bucketData.count++;
      }
    });
    
    // Convertir a array y calcular promedios
    const series = Array.from(buckets.values())
      .map(b => ({
        timestamp: b.timestamp,
        avgResponseTime: b.count > 0 ? Math.round(b.sum / b.count) : null,
        responseTime: b.count > 0 ? Math.round(b.sum / b.count) : null, // Para compatibilidad
        count: b.count,
        status: b.status
      }))
      .sort((a, b) => a.timestamp - b.timestamp);
    
    console.log(`📊 getSeries: ${series.length} puntos generados (bucketSize=${bucketSize}ms)`);
    
    res.json({
      success: true,
      data: series,
      count: series.length,
      monitorId,
      from: Number(from),
      to: Number(to),
      bucketMs: bucketSize
    });
  } catch (error) {
    console.error('getSeries error:', error);
    res.status(500).json({ success: false, error: error.message });
  }
}

export async function postEvent(req, res) {
  try {
    const { monitorId, timestamp, status, responseTime, message, tags, instance } = req.body;
    
    if (!monitorId || !timestamp) {
      return res.status(400).json({ 
        success: false, 
        error: 'Faltan campos requeridos' 
      });
    }
    
    const id = await historyService.addEvent({
      monitorId,
      timestamp,
      status,
      responseTime,
      message,
      tags,
      instance
    });
    
    res.json({
      success: true,
      id,
      message: 'Evento guardado'
    });
  } catch (error) {
    console.error('postEvent error:', error);
    res.status(500).json({ success: false, error: error.message });
  }
}

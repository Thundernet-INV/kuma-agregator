// src/routes/combustible.routes.js
import { Router } from 'express';
import sqlite3 from 'sqlite3';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const router = Router();

// Ruta a la base de datos
const DB_PATH = '/opt/kuma-central/kuma-aggregator/data/history.db';

// ========== ENDPOINTS EXISTENTES ==========

// GET /api/combustible/plantas - Listar todas las plantas
router.get('/plantas', (req, res) => {
    const db = new sqlite3.Database(DB_PATH, sqlite3.OPEN_READONLY);
    
    db.all('SELECT * FROM plantas_combustible_config ORDER BY sede, nombre_monitor', [], (err, rows) => {
        db.close();
        if (err) {
            return res.status(500).json({ success: false, error: err.message });
        }
        res.json({
            success: true,
            count: rows.length,
            data: rows
        });
    });
});

// GET /api/combustible/sedes - Listar sedes disponibles
router.get('/sedes', (req, res) => {
    res.json({
        success: true,
        sedes_disponibles: [
            'San Felipe', 'Guanare', 'Caracas', 'Barquisimeto', 
            'San Carlos', 'Acarigua', 'Barinas', 'San Fernando',
            'Chichiriviche', 'Tucacas', 'Energia'
        ]
    });
});

// ========== NUEVO ENDPOINT: GET /api/combustible/consumo/:nombreMonitor ==========
router.get('/consumo/:nombreMonitor', (req, res) => {
    try {
        const nombreMonitor = decodeURIComponent(req.params.nombreMonitor);
        const db = new sqlite3.Database(DB_PATH, sqlite3.OPEN_READONLY);
        
        // Obtener configuración de la planta
        db.get(
            'SELECT * FROM plantas_combustible_config WHERE nombre_monitor = ?',
            [nombreMonitor],
            (err, config) => {
                if (err) {
                    db.close();
                    return res.status(500).json({ success: false, error: err.message });
                }
                
                if (!config) {
                    db.close();
                    return res.status(404).json({ success: false, error: 'Planta no encontrada' });
                }
                
                // Buscar si hay un evento activo (planta encendida)
                db.get(
                    'SELECT timestamp_inicio FROM planta_eventos WHERE nombre_monitor = ? AND timestamp_fin IS NULL',
                    [nombreMonitor],
                    (err, activo) => {
                        if (err) {
                            db.close();
                            return res.status(500).json({ success: false, error: err.message });
                        }
                        
                        let consumoActual = 0;
                        if (activo) {
                            const ahora = Date.now();
                            const duracionSeg = (ahora - activo.timestamp_inicio) / 1000;
                            consumoActual = (duracionSeg / 3600) * config.consumo_lh;
                        }
                        
                        // Calcular histórico total
                        db.get(
                            'SELECT COALESCE(SUM(consumo_litros), 0) as total FROM planta_eventos WHERE nombre_monitor = ? AND timestamp_fin IS NOT NULL',
                            [nombreMonitor],
                            (err, historico) => {
                                db.close();
                                if (err) {
                                    return res.status(500).json({ success: false, error: err.message });
                                }
                                
                                res.json({
                                    success: true,
                                    data: {
                                        ...config,
                                        esta_encendida_ahora: !!activo,
                                        consumo_actual_sesion: consumoActual,
                                        consumo_total_historico: historico?.total || 0
                                    }
                                });
                            }
                        );
                    }
                );
            }
        );
    } catch (error) {
        console.error('Error en /consumo:', error);
        res.status(500).json({ success: false, error: error.message });
    }
});

// ========== NUEVO ENDPOINT: POST /api/combustible/evento ==========
router.post('/evento', (req, res) => {
    try {
        const { nombre_monitor, estado } = req.body;
        
        if (!nombre_monitor || !estado || !['UP', 'DOWN'].includes(estado)) {
            return res.status(400).json({ 
                success: false, 
                error: 'nombre_monitor y estado (UP/DOWN) requeridos' 
            });
        }

        const db = new sqlite3.Database(DB_PATH);
        const ahora = Date.now();
        
        if (estado === 'UP') {
            // Verificar si ya hay un evento UP activo
            db.get(
                'SELECT id FROM planta_eventos WHERE nombre_monitor = ? AND timestamp_fin IS NULL',
                [nombre_monitor],
                (err, row) => {
                    if (err) {
                        db.close();
                        return res.status(500).json({ success: false, error: err.message });
                    }
                    
                    if (!row) {
                        db.run(
                            'INSERT INTO planta_eventos (nombre_monitor, estado, timestamp_inicio) VALUES (?, ?, ?)',
                            [nombre_monitor, 'UP', ahora],
                            function(err) {
                                db.close();
                                if (err) {
                                    return res.status(500).json({ success: false, error: err.message });
                                }
                                console.log(`🔌 ${nombre_monitor} ENCENDIDA (simulado)`);
                                res.json({ success: true, message: 'Planta encendida' });
                            }
                        );
                    } else {
                        db.close();
                        res.json({ success: true, message: 'Ya estaba encendida' });
                    }
                }
            );
        } else { // DOWN
            // Buscar evento UP activo
            db.get(
                'SELECT id, timestamp_inicio FROM planta_eventos WHERE nombre_monitor = ? AND timestamp_fin IS NULL',
                [nombre_monitor],
                (err, row) => {
                    if (err) {
                        db.close();
                        return res.status(500).json({ success: false, error: err.message });
                    }
                    
                    if (row) {
                        const duracionSeg = (ahora - row.timestamp_inicio) / 1000;
                        
                        // Obtener consumo de la planta
                        db.get(
                            'SELECT consumo_lh FROM plantas_combustible_config WHERE nombre_monitor = ?',
                            [nombre_monitor],
                            (err, config) => {
                                if (err) {
                                    db.close();
                                    return res.status(500).json({ success: false, error: err.message });
                                }
                                
                                const consumoPorHora = config?.consumo_lh || 7.0;
                                const consumoLitros = (duracionSeg / 3600) * consumoPorHora;
                                
                                db.run(
                                    'UPDATE planta_eventos SET timestamp_fin = ?, duracion_segundos = ?, consumo_litros = ? WHERE id = ?',
                                    [ahora, duracionSeg, consumoLitros, row.id],
                                    function(err) {
                                        db.close();
                                        if (err) {
                                            return res.status(500).json({ success: false, error: err.message });
                                        }
                                        console.log(`🔴 ${nombre_monitor} APAGADA - Consumió ${consumoLitros.toFixed(2)}L`);
                                        res.json({ 
                                            success: true, 
                                            message: 'Planta apagada',
                                            consumo: consumoLitros
                                        });
                                    }
                                );
                            }
                        );
                    } else {
                        db.close();
                        res.json({ success: true, message: 'No estaba encendida' });
                    }
                }
            );
        }
    } catch (error) {
        console.error('Error en /evento:', error);
        res.status(500).json({ success: false, error: error.message });
    }
});

// ========== ENDPOINT PARA RESETEAR (OPCIONAL) ==========
router.post('/reset/:nombreMonitor', (req, res) => {
    try {
        const nombreMonitor = decodeURIComponent(req.params.nombreMonitor);
        const db = new sqlite3.Database(DB_PATH);
        
        db.run(
            'DELETE FROM planta_eventos WHERE nombre_monitor = ?',
            [nombreMonitor],
            function(err) {
                db.close();
                if (err) {
                    return res.status(500).json({ success: false, error: err.message });
                }
                res.json({ 
                    success: true, 
                    message: `Historial de ${nombreMonitor} reseteado` 
                });
            }
        );
    } catch (error) {
        console.error('Error en /reset:', error);
        res.status(500).json({ success: false, error: error.message });
    }
});

// ========== ENDPOINTS DE CONSUMO POR PERÍODO ==========

// GET /api/combustible/consumo-periodo/:nombreMonitor?periodo=mensual
router.get('/consumo-periodo/:nombreMonitor', (req, res) => {
  try {
    const nombreMonitor = decodeURIComponent(req.params.nombreMonitor);
    const { periodo = 'diario' } = req.query;
    const db = new sqlite3.Database(DB_PATH, sqlite3.OPEN_READONLY);
    
    const ahora = Date.now();
    let desde;
    let agrupacion;
    
    switch(periodo) {
      case 'diario':
        desde = ahora - (30 * 24 * 60 * 60 * 1000);
        agrupacion = "strftime('%Y-%m-%d', datetime(timestamp_inicio/1000, 'unixepoch'))";
        break;
      case 'semanal':
        desde = ahora - (52 * 7 * 24 * 60 * 60 * 1000);
        agrupacion = "strftime('%Y-%W', datetime(timestamp_inicio/1000, 'unixepoch'))";
        break;
      case 'mensual':
        desde = ahora - (12 * 30 * 24 * 60 * 60 * 1000);
        agrupacion = "strftime('%Y-%m', datetime(timestamp_inicio/1000, 'unixepoch'))";
        break;
      case 'anual':
        desde = 0;
        agrupacion = "strftime('%Y', datetime(timestamp_inicio/1000, 'unixepoch'))";
        break;
      default:
        desde = ahora - (30 * 24 * 60 * 60 * 1000);
        agrupacion = "strftime('%Y-%m-%d', datetime(timestamp_inicio/1000, 'unixepoch'))";
    }
    
    const query = `
      SELECT 
        ${agrupacion} as periodo,
        COUNT(*) as eventos,
        SUM(consumo_litros) as total_consumo,
        AVG(duracion_segundos) / 60 as duracion_promedio_minutos,
        MAX(consumo_litros) as max_consumo,
        MIN(consumo_litros) as min_consumo
      FROM planta_eventos 
      WHERE nombre_monitor = ? 
        AND timestamp_inicio >= ? 
        AND timestamp_fin IS NOT NULL
      GROUP BY periodo
      ORDER BY periodo DESC
    `;
    
    db.all(query, [nombreMonitor, desde], (err, rows) => {
      if (err) {
        console.error('Error en consulta:', err);
        db.close();
        return res.status(500).json({ success: false, error: err.message });
      }
      
      const totalConsumo = rows.reduce((sum, r) => sum + (r.total_consumo || 0), 0);
      const totalEventos = rows.reduce((sum, r) => sum + (r.eventos || 0), 0);
      
      res.json({
        success: true,
        nombre_monitor: nombreMonitor,
        periodo: periodo,
        datos: rows.map(r => ({
          periodo: r.periodo,
          eventos: r.eventos,
          total_consumo: r.total_consumo ? parseFloat(r.total_consumo.toFixed(2)) : 0,
          duracion_promedio_minutos: r.duracion_promedio_minutos ? Math.round(r.duracion_promedio_minutos) : 0,
          max_consumo: r.max_consumo ? parseFloat(r.max_consumo.toFixed(2)) : 0,
          min_consumo: r.min_consumo ? parseFloat(r.min_consumo.toFixed(2)) : 0
        })),
        totales: {
          consumo: parseFloat(totalConsumo.toFixed(2)),
          eventos: totalEventos
        }
      });
      
      db.close();
    });
    
  } catch (error) {
    console.error('Error en /consumo-periodo:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});

// GET /api/combustible/resumen-global?periodo=mensual
router.get('/resumen-global', (req, res) => {
  try {
    const { periodo = 'mensual' } = req.query;
    const db = new sqlite3.Database(DB_PATH, sqlite3.OPEN_READONLY);
    
    const ahora = Date.now();
    let desde;
    
    switch(periodo) {
      case 'diario': desde = ahora - (30 * 24 * 60 * 60 * 1000); break;
      case 'semanal': desde = ahora - (52 * 7 * 24 * 60 * 60 * 1000); break;
      case 'mensual': desde = ahora - (12 * 30 * 24 * 60 * 60 * 1000); break;
      case 'anual': desde = 0; break;
      default: desde = ahora - (30 * 24 * 60 * 60 * 1000);
    }
    
    // Consumo por sede
    db.all(`
      SELECT 
        pc.sede,
        COUNT(DISTINCT pe.nombre_monitor) as plantas_activas,
        COUNT(pe.id) as total_eventos,
        SUM(pe.consumo_litros) as total_consumo
      FROM plantas_combustible_config pc
      LEFT JOIN planta_eventos pe ON pe.nombre_monitor = pc.nombre_monitor 
        AND pe.timestamp_inicio >= ? 
        AND pe.timestamp_fin IS NOT NULL
      GROUP BY pc.sede
      ORDER BY total_consumo DESC
    `, [desde], (err, sedes) => {
      if (err) {
        db.close();
        return res.status(500).json({ success: false, error: err.message });
      }
      
      // Top 10 plantas por consumo
      db.all(`
        SELECT 
          pe.nombre_monitor,
          pc.sede,
          COUNT(pe.id) as eventos,
          SUM(pe.consumo_litros) as total_consumo
        FROM planta_eventos pe
        JOIN plantas_combustible_config pc ON pc.nombre_monitor = pe.nombre_monitor
        WHERE pe.timestamp_inicio >= ? AND pe.timestamp_fin IS NOT NULL
        GROUP BY pe.nombre_monitor
        ORDER BY total_consumo DESC
        LIMIT 10
      `, [desde], (err, topPlantas) => {
        db.close();
        if (err) {
          return res.status(500).json({ success: false, error: err.message });
        }
        
        res.json({
          success: true,
          periodo: periodo,
          resumen: {
            total_sedes: sedes.length,
            total_consumo: sedes.reduce((sum, s) => sum + (s.total_consumo || 0), 0),
            total_eventos: sedes.reduce((sum, s) => sum + (s.total_eventos || 0), 0)
          },
          consumo_por_sede: sedes.map(s => ({
            ...s,
            total_consumo: s.total_consumo ? parseFloat(s.total_consumo.toFixed(2)) : 0
          })),
          top_plantas: topPlantas.map(p => ({
            ...p,
            total_consumo: p.total_consumo ? parseFloat(p.total_consumo.toFixed(2)) : 0
          }))
        });
      });
    });
    
  } catch (error) {
    console.error('Error en /resumen-global:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});

export default router;

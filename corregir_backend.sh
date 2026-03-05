#!/bin/bash
# corregir_backend.sh - Corrige los endpoints de combustible para filtrar por fechas

echo "====================================================="
echo "🔧 CORRIGIENDO ENDPOINTS DE COMBUSTIBLE"
echo "====================================================="

BACKEND_DIR="/opt/kuma-central/kuma-aggregator"
BACKUP_DIR="/root/backups/backend_funcionando_antes_de_empezar_20260305_154153"

# ========== 1. VERIFICAR BACKUP ==========
echo ""
echo "[1] Verificando backup..."

if [ ! -d "$BACKUP_DIR" ]; then
    echo "❌ Backup no encontrado: $BACKUP_DIR"
    exit 1
fi

echo "✅ Backup encontrado: $BACKUP_DIR"

# ========== 2. DETENER BACKEND ==========
echo ""
echo "[2] Deteniendo backend..."

BACKEND_PID=$(ps aux | grep "node.*index.js" | grep -v grep | awk '{print $2}')
if [ -n "$BACKEND_PID" ]; then
    echo "   📍 Backend corriendo con PID: $BACKEND_PID"
    echo "   ⏳ Deteniendo proceso..."
    
    kill -TERM $BACKEND_PID 2>/dev/null
    sleep 3
    
    # Verificar si sigue vivo
    if kill -0 $BACKEND_PID 2>/dev/null; then
        echo "   ⚠️ Proceso no responde, forzando..."
        kill -9 $BACKEND_PID 2>/dev/null
        sleep 2
    fi
fi

echo "✅ Backend detenido"

# ========== 3. HACER BACKUP DE LOS ARCHIVOS A MODIFICAR ==========
echo ""
echo "[3] Creando backup de archivos a modificar..."

mkdir -p "$BACKUP_DIR/modificados_$(date +%Y%m%d_%H%M%S)"
cp "$BACKEND_DIR/src/routes/combustible.routes.js" "$BACKUP_DIR/modificados/" 2>/dev/null
echo "✅ Backup creado"

# ========== 4. CORREGIR ENDPOINTS ==========
echo ""
echo "[4] Corrigiendo endpoints..."

COMBUSTIBLE_ROUTES="$BACKEND_DIR/src/routes/combustible.routes.js"

# Verificar que el archivo existe
if [ ! -f "$COMBUSTIBLE_ROUTES" ]; then
    echo "❌ No se encuentra el archivo: $COMBUSTIBLE_ROUTES"
    exit 1
fi

# Hacer backup temporal
cp "$COMBUSTIBLE_ROUTES" "$COMBUSTIBLE_ROUTES.bak"

# Eliminar los endpoints existentes
sed -i '/router\.get(.resumen-global./,/});/d' "$COMBUSTIBLE_ROUTES"
sed -i '/router\.get(.consumo-periodo./,/});/d' "$COMBUSTIBLE_ROUTES"

# Agregar los endpoints corregidos al final del archivo
cat >> "$COMBUSTIBLE_ROUTES" << 'END'

// ========== ENDPOINT CORREGIDO: GET /api/combustible/resumen-global ==========
router.get('/resumen-global', (req, res) => {
  try {
    const { periodo = 'mensual', sede, fecha_inicio, fecha_fin } = req.query;
    console.log('📊 Resumen global -', { periodo, sede, fecha_inicio, fecha_fin });
    
    const db = new sqlite3.Database(DB_PATH, sqlite3.OPEN_READONLY);
    
    const ahora = Date.now();
    let desde;
    let hasta = ahora;
    
    // ============================================
    // 1. DETERMINAR RANGO DE FECHAS
    // ============================================
    if (fecha_inicio && fecha_fin) {
      desde = new Date(fecha_inicio).getTime();
      hasta = new Date(fecha_fin).getTime() + (24 * 60 * 60 * 1000) - 1;
      console.log(`   📅 Rango: ${new Date(desde).toISOString()} → ${new Date(hasta).toISOString()}`);
    } else {
      switch(periodo) {
        case 'diario': desde = ahora - (30 * 24 * 60 * 60 * 1000); break;
        case 'semanal': desde = ahora - (52 * 7 * 24 * 60 * 60 * 1000); break;
        case 'mensual': desde = ahora - (12 * 30 * 24 * 60 * 60 * 1000); break;
        case 'anual': desde = 0; break;
        default: desde = ahora - (30 * 24 * 60 * 60 * 1000);
      }
    }
    
    // ============================================
    // 2. CONSUMO POR SEDE
    // ============================================
    let querySedes = `
      SELECT 
        pc.sede,
        COUNT(DISTINCT pe.nombre_monitor) as plantas_activas,
        COUNT(pe.id) as total_eventos,
        SUM(pe.consumo_litros) as total_consumo
      FROM plantas_combustible_config pc
      LEFT JOIN planta_eventos pe ON pe.nombre_monitor = pc.nombre_monitor 
        AND pe.timestamp_inicio >= ? 
        AND pe.timestamp_inicio <= ?
        AND pe.timestamp_fin IS NOT NULL
    `;
    
    const paramsSedes = [desde, hasta];
    
    if (sede && sede !== 'undefined' && sede !== 'todas' && sede !== '') {
      querySedes += ` WHERE pc.sede = ?`;
      paramsSedes.push(sede);
    }
    
    querySedes += ` GROUP BY pc.sede ORDER BY total_consumo DESC`;
    
    db.all(querySedes, paramsSedes, (err, sedes) => {
      if (err) {
        db.close();
        return res.status(500).json({ success: false, error: err.message });
      }
      
      // ============================================
      // 3. TOP 10 PLANTAS
      // ============================================
      let queryTop = `
        SELECT 
          pe.nombre_monitor,
          pc.sede,
          COUNT(pe.id) as eventos,
          SUM(pe.consumo_litros) as total_consumo
        FROM planta_eventos pe
        JOIN plantas_combustible_config pc ON pc.nombre_monitor = pe.nombre_monitor
        WHERE pe.timestamp_inicio >= ? 
          AND pe.timestamp_inicio <= ?
          AND pe.timestamp_fin IS NOT NULL
      `;
      
      const paramsTop = [desde, hasta];
      
      if (sede && sede !== 'undefined' && sede !== 'todas' && sede !== '') {
        queryTop += ` AND pc.sede = ?`;
        paramsTop.push(sede);
      }
      
      queryTop += ` GROUP BY pe.nombre_monitor ORDER BY total_consumo DESC LIMIT 10`;
      
      db.all(queryTop, paramsTop, (err, topPlantas) => {
        if (err) {
          db.close();
          return res.status(500).json({ success: false, error: err.message });
        }
        
        // Calcular totales
        const sedesConConsumo = sedes.filter(s => s.total_consumo > 0);
        const totalConsumo = sedesConConsumo.reduce((sum, s) => sum + (s.total_consumo || 0), 0);
        
        res.json({
          success: true,
          periodo: fecha_inicio && fecha_fin ? 'personalizado' : periodo,
          sede_filtrada: sede || 'todas',
          rango_fechas: fecha_inicio && fecha_fin ? { inicio: fecha_inicio, fin: fecha_fin } : null,
          resumen: {
            total_sedes: sedesConConsumo.length,
            total_consumo: parseFloat(totalConsumo.toFixed(2)),
            total_eventos: sedesConConsumo.reduce((sum, s) => sum + s.total_eventos, 0)
          },
          consumo_por_sede: sedesConConsumo.map(s => ({
            sede: s.sede,
            plantas_activas: s.plantas_activas,
            total_eventos: s.total_eventos,
            total_consumo: parseFloat(s.total_consumo.toFixed(2))
          })),
          top_plantas: topPlantas.map(p => ({
            nombre_monitor: p.nombre_monitor,
            sede: p.sede,
            eventos: p.eventos,
            total_consumo: parseFloat(p.total_consumo.toFixed(2))
          }))
        });
        
        db.close();
      });
    });
    
  } catch (error) {
    console.error('Error:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});

// ========== ENDPOINT CORREGIDO: GET /api/combustible/consumo-periodo/:nombreMonitor ==========
router.get('/consumo-periodo/:nombreMonitor', (req, res) => {
  try {
    const nombreMonitor = decodeURIComponent(req.params.nombreMonitor);
    const { periodo = 'diario', fecha_inicio, fecha_fin } = req.query;
    
    console.log(`📊 Consumo ${nombreMonitor}:`, { periodo, fecha_inicio, fecha_fin });
    
    const db = new sqlite3.Database(DB_PATH, sqlite3.OPEN_READONLY);
    
    const ahora = Date.now();
    let desde;
    let hasta = ahora;
    let agrupacion;
    
    // ============================================
    // 1. DETERMINAR RANGO DE FECHAS
    // ============================================
    if (fecha_inicio && fecha_fin) {
      desde = new Date(fecha_inicio).getTime();
      hasta = new Date(fecha_fin).getTime() + (24 * 60 * 60 * 1000) - 1;
      agrupacion = "strftime('%Y-%m-%d', datetime(timestamp_inicio/1000, 'unixepoch'))";
    } else {
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
    }
    
    // ============================================
    // 2. CONSULTAR DATOS
    // ============================================
    const query = `
      SELECT 
        ${agrupacion} as periodo,
        COUNT(*) as eventos,
        SUM(consumo_litros) as total_consumo,
        AVG(duracion_segundos) / 60 as duracion_promedio_minutos
      FROM planta_eventos 
      WHERE nombre_monitor = ? 
        AND timestamp_inicio >= ? 
        AND timestamp_inicio <= ?
        AND timestamp_fin IS NOT NULL
      GROUP BY periodo
      ORDER BY periodo DESC
    `;
    
    db.all(query, [nombreMonitor, desde, hasta], (err, rows) => {
      if (err) {
        db.close();
        return res.status(500).json({ success: false, error: err.message });
      }
      
      const totalConsumo = rows.reduce((sum, r) => sum + (r.total_consumo || 0), 0);
      
      res.json({
        success: true,
        nombre_monitor: nombreMonitor,
        periodo: fecha_inicio && fecha_fin ? 'personalizado' : periodo,
        rango_fechas: fecha_inicio && fecha_fin ? { inicio: fecha_inicio, fin: fecha_fin } : null,
        datos: rows.map(r => ({
          periodo: r.periodo,
          eventos: r.eventos,
          total_consumo: parseFloat(r.total_consumo.toFixed(2)),
          duracion_promedio_minutos: Math.round(r.duracion_promedio_minutos || 0)
        })),
        totales: {
          consumo: parseFloat(totalConsumo.toFixed(2)),
          eventos: rows.reduce((sum, r) => sum + r.eventos, 0)
        }
      });
      
      db.close();
    });
    
  } catch (error) {
    console.error('Error:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});
END

echo "✅ Endpoints corregidos"

# ========== 5. VERIFICAR SINTAXIS ==========
echo ""
echo "[5] Verificando sintaxis..."

cd "$BACKEND_DIR"
node --check "src/routes/combustible.routes.js" 2>/dev/null
if [ $? -eq 0 ]; then
    echo "✅ Sintaxis correcta"
else
    echo "❌ Error de sintaxis - restaurando backup..."
    cp "$COMBUSTIBLE_ROUTES.bak" "$COMBUSTIBLE_ROUTES"
    exit 1
fi

# ========== 6. INICIAR BACKEND ==========
echo ""
echo "[6] Iniciando backend..."

cd "$BACKEND_DIR"
NODE_ENV=production nohup node src/index.js > /tmp/kuma-backend.log 2>&1 &
sleep 5

BACKEND_PID=$(ps aux | grep "node.*index.js" | grep -v grep | awk '{print $2}')
if [ -n "$BACKEND_PID" ]; then
    echo "✅ Backend iniciado con PID: $BACKEND_PID"
else
    echo "❌ Error iniciando backend"
    tail -20 /tmp/kuma-backend.log
    exit 1
fi

# ========== 7. PROBAR ENDPOINTS ==========
echo ""
echo "[7] Probando endpoints..."

# Esperar que inicie
sleep 3

# Health check
curl -s "http://localhost:8080/health" | grep -q "ok" && echo "✅ Health check OK" || echo "❌ Health check falló"

# Probar rango personalizado (últimos 7 días)
echo ""
echo "📅 Probando con últimos 7 días..."
FECHA_INICIO=$(date -d "7 days ago" +%Y-%m-%d)
FECHA_FIN=$(date +%Y-%m-%d)

echo -n "   • /resumen-global (Caracas): "
curl -s "http://localhost:8080/api/combustible/resumen-global?fecha_inicio=$FECHA_INICIO&fecha_fin=$FECHA_FIN&sede=Caracas" | grep -q "success" && echo "✅" || echo "❌"

echo -n "   • /consumo-periodo (PLANTA HATILLO): "
curl -s "http://localhost:8080/api/combustible/consumo-periodo/PLANTA%20ELECTRICA%20HATILLO?fecha_inicio=$FECHA_INICIO&fecha_fin=$FECHA_FIN" | grep -q "success" && echo "✅" || echo "❌"

# ========== 8. REINICIAR FRONTEND ==========
echo ""
echo "[8] Reiniciando frontend..."

FRONTEND_DIR="/home/thunder/kuma-dashboard-clean/kuma-ui"
if [ -d "$FRONTEND_DIR" ]; then
    cd "$FRONTEND_DIR"
    pkill -f "vite" 2>/dev/null || true
    npm run dev &
    echo "✅ Frontend reiniciado en http://10.10.31.31:5173"
else
    echo "⚠️ Frontend no encontrado en $FRONTEND_DIR"
fi

# ========== 9. MOSTRAR INSTRUCCIONES ==========
echo ""
echo "====================================================="
echo "✅✅ CORRECCIÓN COMPLETADA"
echo "====================================================="
echo ""
echo "📊 PRUEBA EN EL FRONTEND:"
echo "   1. Abre http://10.10.31.31:5173"
echo "   2. Ve a Reportes de Combustible (#/reportes)"
echo "   3. Selecciona 'Rango personalizado'"
echo "   4. Elige fechas diferentes"
echo "   5. ✅ Los números deben cambiar"
echo ""
echo "📌 PARA VER LOGS: tail -f /tmp/kuma-backend.log"
echo "📌 PARA RESTAURAR: cp $COMBUSTIBLE_ROUTES.bak $COMBUSTIBLE_ROUTES"
echo ""
echo "====================================================="

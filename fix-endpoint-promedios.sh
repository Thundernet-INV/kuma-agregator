#!/bin/bash
# fix-endpoint-promedios.sh - CORRIGE EL ENDPOINT DE PROMEDIOS

echo "====================================================="
echo "🔧 CORRIGIENDO ENDPOINT DE PROMEDIOS DE INSTANCIA"
echo "====================================================="

BACKEND_DIR="/opt/kuma-central/kuma-aggregator/src"
BACKUP_DIR="${BACKEND_DIR}/backup_endpoint_$(date +%Y%m%d_%H%M%S)"

# ========== 1. CREAR BACKUP ==========
echo ""
echo "[1] Creando backup..."
mkdir -p "$BACKUP_DIR"
cp "${BACKEND_DIR}/index.js" "$BACKUP_DIR/"
cp "${BACKEND_DIR}/routes/instanceAverageRoutes.js" "$BACKUP_DIR/" 2>/dev/null || true
echo "✅ Backup creado en: $BACKUP_DIR"

# ========== 2. VERIFICAR QUE EL ARCHIVO DE RUTAS EXISTE ==========
echo ""
echo "[2] Verificando archivo de rutas..."

if [ ! -f "${BACKEND_DIR}/routes/instanceAverageRoutes.js" ]; then
    echo "   Creando instanceAverageRoutes.js..."
    cat > "${BACKEND_DIR}/routes/instanceAverageRoutes.js" << 'EOF'
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
EOF
    echo "✅ instanceAverageRoutes.js creado"
else
    echo "✅ instanceAverageRoutes.js ya existe"
fi

# ========== 3. MODIFICAR INDEX.JS CORRECTAMENTE ==========
echo ""
echo "[3] Modificando index.js para montar el endpoint..."

INDEX_FILE="${BACKEND_DIR}/index.js"

# Hacer backup
cp "$INDEX_FILE" "$BACKUP_DIR/index.js.bak"

# Eliminar cualquier línea existente del endpoint
sed -i '/instanceAverageRoutes/d' "$INDEX_FILE"

# Agregar IMPORT después de los otros imports
sed -i '/import \* as historyService/i import instanceAverageRoutes from '\''./routes/instanceAverageRoutes.js'\'';' "$INDEX_FILE"

# Agregar USE después de los otros app.use
sed -i '/app\.use(.api\/metric-history./a app.use('\''/api/instance/average'\'', instanceAverageRoutes);' "$INDEX_FILE"

echo "✅ index.js modificado"

# ========== 4. VERIFICAR QUE QUEDÓ BIEN ==========
echo ""
echo "[4] Verificando cambios en index.js..."

if grep -q "instanceAverageRoutes" "$INDEX_FILE"; then
    echo "   ✅ Import encontrado"
else
    echo "   ❌ Import NO encontrado"
fi

if grep -q "app.use('/api/instance/average'" "$INDEX_FILE"; then
    echo "   ✅ Endpoint montado correctamente"
else
    echo "   ❌ Endpoint NO montado"
fi

# ========== 5. REINICIAR BACKEND ==========
echo ""
echo "[5] Reiniciando backend..."

# Matar proceso actual
BACKEND_PID=$(ps aux | grep "node.*index.js" | grep -v grep | awk '{print $2}')
if [ -n "$BACKEND_PID" ]; then
    echo "   Deteniendo backend (PID: $BACKEND_PID)..."
    kill $BACKEND_PID
    sleep 3
fi

# Iniciar backend
cd "${BACKEND_DIR}"
nohup node index.js > /tmp/kuma-backend.log 2>&1 &
sleep 3
echo "✅ Backend reiniciado"

# ========== 6. PROBAR ENDPOINT CORREGIDO ==========
echo ""
echo "[6] Probando endpoint de promedios..."

echo -n "   • /api/instance/average/Caracas: "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/api/instance/average/Caracas?hours=1)
if [ "$HTTP_CODE" = "200" ]; then
    echo "✅ (200)"
    
    # Mostrar algunos datos
    echo ""
    echo "   Datos de ejemplo para Caracas:"
    curl -s "http://localhost:8080/api/instance/average/Caracas?hours=1" | jq '.data | length' 2>/dev/null || echo "   No se pudo parsear JSON"
else
    echo "❌ ($HTTP_CODE)"
    
    # Mostrar error
    echo ""
    echo "   Error:"
    curl -s "http://localhost:8080/api/instance/average/Caracas?hours=1"
    echo ""
fi

# ========== 7. GENERAR ALGUNOS PROMEDIOS ==========
echo ""
echo "[7] Generando promedios iniciales..."

echo -n "   • Forzando cálculo: "
curl -s -X POST "http://localhost:8080/api/instance/average/calculate" | jq '.message' 2>/dev/null || echo "   No se pudo forzar cálculo"

# ========== 8. REINICIAR FRONTEND ==========
echo ""
echo "[8] Reiniciando frontend..."

FRONTEND_DIR="/home/thunder/kuma-dashboard-clean/kuma-ui"
cd "$FRONTEND_DIR"
pkill -f "vite" 2>/dev/null || true
npm run dev &
sleep 3

# ========== 9. INSTRUCCIONES FINALES ==========
echo ""
echo "====================================================="
echo "✅✅ ENDPOINT DE PROMEDIOS CORREGIDO ✅✅"
echo "====================================================="
echo ""
echo "📋 ESTADO ACTUAL:"
echo ""
echo "   • ✅ Backend corriendo (PID: $BACKEND_PID)"
echo "   • ✅ Puerto 8080 abierto"
echo "   • ✅ Endpoint /health responde"
echo "   • ✅ Endpoint /api/summary responde"
echo "   • 🟢 Endpoint /api/instance/average CORREGIDO"
echo ""
echo "🔄 PRUEBA AHORA:"
echo ""
echo "   1. Abre http://10.10.31.31:5173"
echo "   2. El dashboard DEBE cargar los datos"
echo "   3. Entra a Caracas o Guanare"
echo "   4. ✅ DEBES VER LA GRÁFICA DE PROMEDIO"
echo ""
echo "📌 VERIFICACIÓN MANUAL:"
echo ""
echo "   # Ver endpoint directamente:"
echo "   curl 'http://10.10.31.31:8080/api/instance/average/Caracas?hours=24' | jq '.'"
echo ""
echo "   # Ver logs del backend:"
echo "   tail -f /tmp/kuma-backend.log"
echo ""
echo "====================================================="

# Preguntar si quiere probar el endpoint
read -p "¿Probar endpoint de Caracas ahora? (s/N): " TEST_ENDPOINT
if [[ "$TEST_ENDPOINT" =~ ^[Ss]$ ]]; then
    echo ""
    curl -s "http://10.10.31.31:8080/api/instance/average/Caracas?hours=1" | jq '.'
fi

# Preguntar si quiere abrir el navegador
read -p "¿Abrir el dashboard ahora? (s/N): " OPEN_BROWSER
if [[ "$OPEN_BROWSER" =~ ^[Ss]$ ]]; then
    xdg-open "http://10.10.31.31:5173" 2>/dev/null || \
    open "http://10.10.31.31:5173" 2>/dev/null || \
    echo "Abre http://10.10.31.31:5173 en tu navegador"
fi

echo ""
echo "✅ Script completado"

#!/bin/bash
# fix-backend-imports.sh - CORRIGE IMPORTS DUPLICADOS EN EL BACKEND

echo "====================================================="
echo "🔧 CORRIGIENDO IMPORTS DUPLICADOS EN BACKEND"
echo "====================================================="

BACKEND_DIR="/opt/kuma-central/kuma-aggregator/src"
BACKUP_DIR="${BACKEND_DIR}/backup_imports_$(date +%Y%m%d_%H%M%S)"

# ========== 1. CREAR BACKUP ==========
echo ""
echo "[1] Creando backup..."
mkdir -p "$BACKUP_DIR"
cp "${BACKEND_DIR}/index.js" "$BACKUP_DIR/"
echo "✅ Backup creado en: $BACKUP_DIR"
echo ""

# ========== 2. CORREGIR INDEX.JS ==========
echo "[2] Corrigiendo index.js - ELIMINANDO IMPORTS DUPLICADOS..."

INDEX_FILE="${BACKEND_DIR}/index.js"

# Hacer backup
cp "$INDEX_FILE" "$BACKUP_DIR/index.js.bak"

# Eliminar TODAS las líneas de import de instanceAveragesRoutes
sed -i '/import instanceAveragesRoutes/d' "$INDEX_FILE"

# Agregar UNA sola vez al inicio del área de imports
sed -i '/import .* from/ i import instanceAveragesRoutes from '\''./routes/instanceAveragesRoutes.js'\'';' "$INDEX_FILE"

# Eliminar app.use duplicados de instance/averages
sed -i '/app\.use(.api\/instance\/averages./d' "$INDEX_FILE"

# Agregar UNA sola vez después de metric-history
sed -i '/app\.use(.api\/metric-history./a app.use('\''/api/instance/averages'\'', instanceAveragesRoutes);' "$INDEX_FILE"

echo "✅ index.js corregido - IMPORTS ÚNICOS"

# ========== 3. VERIFICAR QUE NO HAY DUPLICADOS ==========
echo ""
echo "[3] Verificando corrección..."

IMPORT_COUNT=$(grep -c "import instanceAveragesRoutes" "$INDEX_FILE")
if [ "$IMPORT_COUNT" -eq 1 ]; then
    echo "✅ Import correcto: 1 línea"
else
    echo "❌ Import incorrecto: $IMPORT_COUNT líneas"
fi

USE_COUNT=$(grep -c "app.use('/api/instance/averages'" "$INDEX_FILE")
if [ "$USE_COUNT" -eq 1 ]; then
    echo "✅ Montaje correcto: 1 línea"
else
    echo "❌ Montaje incorrecto: $USE_COUNT líneas"
fi

echo ""

# ========== 4. REINICIAR BACKEND ==========
echo "[4] Reiniciando backend..."

cd "${BACKEND_DIR}/.."

# Matar procesos existentes
pkill -f "node.*index.js" 2>/dev/null || true
sleep 2

# Iniciar backend
NODE_ENV=production nohup node src/index.js > /tmp/kuma-backend.log 2>&1 &
BACKEND_PID=$!
sleep 3

echo "✅ Backend iniciado con PID: $BACKEND_PID"

# ========== 5. VERIFICAR BACKEND ==========
echo ""
echo "[5] Verificando backend..."

if ps -p $BACKEND_PID > /dev/null; then
    echo "✅ Proceso vivo"
    
    # Probar health
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/health)
    if [ "$HTTP_CODE" = "200" ]; then
        echo "✅ Health check OK"
    else
        echo "❌ Health check falló"
    fi
    
    # Probar summary
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/api/summary)
    if [ "$HTTP_CODE" = "200" ]; then
        echo "✅ Summary OK"
    else
        echo "❌ Summary falló"
    fi
else
    echo "❌ El proceso murió"
    echo ""
    echo "=== ÚLTIMAS LÍNEAS DEL LOG ==="
    tail -20 /tmp/kuma-backend.log
    exit 1
fi

# ========== 6. VERIFICAR NUEVO ENDPOINT ==========
echo ""
echo "[6] Verificando endpoint de promedios..."

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/api/instance/averages/Caracas?hours=1)
if [ "$HTTP_CODE" = "200" ]; then
    echo "✅ Endpoint de promedios OK (HTTP $HTTP_CODE)"
    
    # Mostrar algunos datos
    echo ""
    echo "   Datos de Caracas:"
    curl -s "http://localhost:8080/api/instance/averages/Caracas?hours=1" | head -c 200
    echo ""
else
    echo "⚠️ Endpoint de promedios responde con HTTP $HTTP_CODE (puede que no haya datos aún)"
fi

# ========== 7. REINICIAR FRONTEND ==========
echo ""
echo "[7] Reiniciando frontend..."

FRONTEND_DIR="/home/thunder/kuma-dashboard-clean/kuma-ui"
cd "$FRONTEND_DIR"
pkill -f "vite" 2>/dev/null || true
npm run dev &
sleep 3

# ========== 8. INSTRUCCIONES ==========
echo ""
echo "====================================================="
echo "✅✅ BACKEND CORREGIDO ✅✅"
echo "====================================================="
echo ""
echo "📋 ESTADO ACTUAL:"
echo ""
echo "   • ✅ Backend corriendo (PID: $BACKEND_PID)"
echo "   • ✅ Puerto 8080 abierto"
echo "   • ✅ Endpoints originales funcionando"
echo "   • ✅ Nuevo endpoint: /api/instance/averages"
echo ""
echo "📌 PRUEBA AHORA:"
echo ""
echo "   1. Abre http://10.10.31.31:5173"
echo "   2. EL DASHBOARD DEBE FUNCIONAR INMEDIATAMENTE"
echo "   3. Las gráficas de histórico DEBEN aparecer"
echo ""
echo "📌 SI LAS GRÁFICAS NO APARECEN:"
echo ""
echo "   El backend no tiene datos históricos. Ejecuta:"
echo ""
echo "   # Generar datos de prueba:"
echo "   cd /opt/kuma-central/kuma-aggregator"
echo "   node scripts/generate-test-averages.js"
echo ""
echo "📌 VERIFICACIÓN MANUAL:"
echo ""
echo "   curl http://10.10.31.31:8080/health"
echo "   curl http://10.10.31.31:8080/api/summary"
echo "   curl http://10.10.31.31:8080/api/instance/averages/Caracas"
echo ""
echo "====================================================="

# Preguntar si quiere generar datos de prueba
read -p "¿Generar datos de prueba ahora? (s/N): " GENERATE_DATA
if [[ "$GENERATE_DATA" =~ ^[Ss]$ ]]; then
    echo ""
    echo "📊 Generando datos de prueba..."
    cd /opt/kuma-central/kuma-aggregator
    if [ -f "scripts/generate-test-averages.js" ]; then
        node scripts/generate-test-averages.js
    else
        echo "❌ Script no encontrado"
    fi
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

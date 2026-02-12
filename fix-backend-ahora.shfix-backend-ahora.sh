#!/bin/bash
# fix-backend-ahora.sh - ARRANCA EL BACKEND AHORA MISMO

echo "====================================================="
echo "🚀 ARRANCANDO BACKEND KUMA-AGGREGATOR"
echo "====================================================="

BACKEND_DIR="/opt/kuma-central/kuma-aggregator"
LOG_FILE="/tmp/kuma-backend.log"

# ========== 1. MATAR PROCESOS EXISTENTES ==========
echo ""
echo "[1] Matando procesos existentes..."
pkill -f "node.*index.js" || true
pkill -f "node.*kuma-aggregator" || true
sleep 2
echo "✅ Procesos terminados"

# ========== 2. VERIFICAR DIRECTORIO ==========
echo ""
echo "[2] Verificando directorio del backend..."
cd "$BACKEND_DIR" || { echo "❌ No se puede acceder a $BACKEND_DIR"; exit 1; }
echo "✅ Directorio: $(pwd)"

# ========== 3. VERIFICAR NODE JS ==========
echo ""
echo "[3] Verificando Node.js..."
node --version || { echo "❌ Node.js no está instalado"; exit 1; }
npm --version || { echo "❌ npm no está instalado"; exit 1; }
echo "✅ Node.js OK"

# ========== 4. VERIFICAR DEPENDENCIAS ==========
echo ""
echo "[4] Verificando dependencias..."
if [ ! -d "node_modules" ]; then
    echo "   Instalando dependencias (puede tomar 1 minuto)..."
    npm install
else
    echo "✅ node_modules existe"
fi

# ========== 5. VERIFICAR ARCHIVO INDEX.JS ==========
echo ""
echo "[5] Verificando index.js..."
if [ -f "src/index.js" ]; then
    echo "✅ src/index.js encontrado"
else
    echo "❌ src/index.js NO encontrado"
    exit 1
fi

# ========== 6. VERIFICAR PUERTO 8080 ==========
echo ""
echo "[6] Verificando puerto 8080..."
if ss -tlnp | grep -q ":8080"; then
    OLD_PID=$(ss -tlnp | grep ":8080" | awk -F',' '{print $2}' | awk -F'=' '{print $2}')
    echo "   ⚠️ Puerto 8080 ocupado por PID: $OLD_PID"
    echo "   Terminando proceso..."
    kill -9 $OLD_PID 2>/dev/null || true
    sleep 2
fi
echo "✅ Puerto 8080 libre"

# ========== 7. INICIAR BACKEND ==========
echo ""
echo "[7] Iniciando backend..."
cd "$BACKEND_DIR"

# Iniciar con nohup para que corra en background
NODE_ENV=production nohup node src/index.js > "$LOG_FILE" 2>&1 &
BACKEND_PID=$!
echo "   PID: $BACKEND_PID"
echo "   Log: $LOG_FILE"

# ========== 8. ESPERAR Y VERIFICAR ==========
echo ""
echo "[8] Esperando 5 segundos..."
sleep 5

# Verificar que el proceso sigue vivo
if ps -p $BACKEND_PID > /dev/null; then
    echo "✅ Proceso vivo (PID: $BACKEND_PID)"
else
    echo "❌ El proceso murió"
    echo "   Últimas líneas del log:"
    tail -20 "$LOG_FILE"
    exit 1
fi

# ========== 9. PROBAR ENDPOINTS ==========
echo ""
echo "[9] Probando endpoints..."

echo -n "   • /health: "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/health)
if [ "$HTTP_CODE" = "200" ]; then
    echo "✅ (200)"
else
    echo "❌ ($HTTP_CODE)"
fi

echo -n "   • /api/summary: "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/api/summary)
if [ "$HTTP_CODE" = "200" ]; then
    echo "✅ (200)"
else
    echo "❌ ($HTTP_CODE)"
fi

echo -n "   • /api/instance/average/Caracas: "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/api/instance/average/Caracas?hours=1)
if [ "$HTTP_CODE" = "200" ]; then
    echo "✅ (200)"
else
    echo "❌ ($HTTP_CODE)"
fi

# ========== 10. MOSTRAR LOGS ==========
echo ""
echo "[10] Últimas 20 líneas del log:"
echo "----------------------------------------"
tail -20 "$LOG_FILE"
echo "----------------------------------------"

# ========== 11. VERIFICAR CONEXIÓN DESDE LA IP ==========
echo ""
echo "[11] Verificando conexión desde 10.10.31.31..."
echo -n "   • http://10.10.31.31:8080/health: "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://10.10.31.31:8080/health)
if [ "$HTTP_CODE" = "200" ]; then
    echo "✅ (200)"
else
    echo "❌ ($HTTP_CODE)"
fi

# ========== 12. REINICIAR FRONTEND ==========
echo ""
echo "[12] Reiniciando frontend..."

FRONTEND_DIR="/home/thunder/kuma-dashboard-clean/kuma-ui"
cd "$FRONTEND_DIR"
pkill -f "vite" 2>/dev/null || true
npm run dev &
sleep 3

echo ""
echo "====================================================="
echo "✅✅ BACKEND INICIADO CORRECTAMENTE ✅✅"
echo "====================================================="
echo ""
echo "📋 INFORMACIÓN:"
echo "   • PID: $BACKEND_PID"
echo "   • Log: tail -f $LOG_FILE"
echo "   • URL: http://10.10.31.31:8080"
echo ""
echo "🔄 PRUEBA AHORA:"
echo "   1. Abre http://10.10.31.31:5173"
echo "   2. El dashboard DEBE cargar los datos"
echo "   3. Las gráficas DEBEN aparecer"
echo ""
echo "📌 SI SIGUE SIN FUNCIONAR:"
echo "   tail -f $LOG_FILE  # Ver errores en tiempo real"
echo ""
echo "====================================================="

# Preguntar si quiere seguir logs
read -p "¿Seguir logs en tiempo real? (s/N): " TAIL_LOGS
if [[ "$TAIL_LOGS" =~ ^[Ss]$ ]]; then
    echo ""
    echo "Presiona Ctrl+C para salir"
    echo "----------------------------------------"
    tail -f "$LOG_FILE"
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

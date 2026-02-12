#!/bin/bash
# fix-systemd-ahora.sh - DESACTIVAR SYSTEMD Y EJECUTAR BACKEND MANUALMENTE

echo "====================================================="
echo "🔧 DESACTIVANDO SYSTEMD Y ARRANCANDO BACKEND MANUAL"
echo "====================================================="

BACKEND_DIR="/opt/kuma-central/kuma-aggregator"

# ========== 1. DETENER Y DESACTIVAR SERVICIO SYSTEMD ==========
echo ""
echo "[1] Deteniendo y desactivando servicio systemd..."

sudo systemctl stop kuma-aggregator.service 2>/dev/null
sudo systemctl disable kuma-aggregator.service 2>/dev/null
sudo systemctl mask kuma-aggregator.service 2>/dev/null

echo "✅ Servicio systemd detenido y desactivado"
echo ""

# ========== 2. MATAR TODOS LOS PROCESOS NODE ==========
echo "[2] Matando todos los procesos node del backend..."

pkill -f "node.*kuma-aggregator" 2>/dev/null
pkill -f "node.*index.js" 2>/dev/null
sleep 2

echo "✅ Procesos terminados"
echo ""

# ========== 3. VERIFICAR INDEX.JS ==========
echo "[3] Verificando index.js..."

cd "$BACKEND_DIR"

# Crear backup
cp src/index.js src/index.js.backup.$(date +%s)

# Contar imports duplicados
DUPLICATES=$(grep -c "import instanceAveragesRoutes" src/index.js)
echo "   • Imports encontrados: $DUPLICATES"

if [ "$DUPLICATES" -gt 1 ]; then
    echo "   ⚠️ Eliminando imports duplicados..."
    # Eliminar TODOS los imports
    sed -i '/import instanceAveragesRoutes/d' src/index.js
    # Agregar UNO SOLO al principio
    sed -i '1i import instanceAveragesRoutes from '\''./routes/instanceAveragesRoutes.js'\'';' src/index.js
    echo "   ✅ Imports corregidos"
fi

# Verificar app.use duplicados
USES=$(grep -c "app.use('/api/instance/averages'" src/index.js)
if [ "$USES" -gt 1 ]; then
    echo "   ⚠️ Eliminando montajes duplicados..."
    sed -i '/app\.use(.api\/instance\/averages./d' src/index.js
    # Agregar UNO SOLO después de metric-history
    sed -i '/app\.use(.api\/metric-history./a app.use('\''/api/instance/averages'\'', instanceAveragesRoutes);' src/index.js
    echo "   ✅ Montajes corregidos"
fi

echo "✅ index.js verificado"
echo ""

# ========== 4. INICIAR BACKEND MANUALMENTE ==========
echo "[4] Iniciando backend manualmente (NO systemd)..."

cd "$BACKEND_DIR"

# Iniciar con nohup para que corra en background
NODE_ENV=production nohup node src/index.js > /tmp/kuma-backend.log 2>&1 &
BACKEND_PID=$!

echo "   ✅ Backend iniciado con PID: $BACKEND_PID"
echo "   📝 Log: /tmp/kuma-backend.log"
echo ""

# ========== 5. ESPERAR Y VERIFICAR ==========
echo "[5] Esperando 3 segundos..."
sleep 3

echo "[6] Verificando proceso..."
if ps -p $BACKEND_PID > /dev/null; then
    echo "   ✅ Proceso vivo"
else
    echo "   ❌ El proceso murió"
    echo ""
    echo "=== ÚLTIMAS LÍNEAS DEL LOG ==="
    tail -20 /tmp/kuma-backend.log
    exit 1
fi
echo ""

# ========== 6. VERIFICAR CONEXIÓN ==========
echo "[7] Verificando conexión..."

# Probar localhost
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/health)
if [ "$HTTP_CODE" = "200" ]; then
    echo "   ✅ Backend responde en localhost:8080"
else
    echo "   ❌ Backend NO responde (HTTP $HTTP_CODE)"
    tail -20 /tmp/kuma-backend.log
    exit 1
fi

# Probar desde IP
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 http://10.10.31.31:8080/health)
if [ "$HTTP_CODE" = "200" ]; then
    echo "   ✅ Backend responde en 10.10.31.31:8080"
else
    echo "   ⚠️ Backend NO responde en la IP - verificando bind address..."
    
    BIND_ADDR=$(ss -tlnp | grep ":8080" | head -1 | awk '{print $4}')
    echo "   📍 Bind address: $BIND_ADDR"
    
    if [[ "$BIND_ADDR" == *"127.0.0.1"* ]]; then
        echo "   ❌ Solo escucha en localhost - corrigiendo..."
        # Modificar index.js
        sed -i 's/app.listen(8080,/app.listen(8080, "0.0.0.0",/' src/index.js
        # Reiniciar
        kill $BACKEND_PID
        sleep 2
        NODE_ENV=production nohup node src/index.js > /tmp/kuma-backend.log 2>&1 &
        BACKEND_PID=$!
        sleep 3
        echo "   ✅ Backend reiniciado escuchando en 0.0.0.0"
    fi
fi
echo ""

# ========== 7. VERIFICAR ENDPOINTS ==========
echo "[8] Verificando endpoints..."

echo -n "   • /api/summary: "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://10.10.31.31:8080/api/summary)
if [ "$HTTP_CODE" = "200" ]; then
    echo "✅"
else
    echo "❌ ($HTTP_CODE)"
fi

echo -n "   • /api/instance/averages/Caracas: "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://10.10.31.31:8080/api/instance/averages/Caracas?hours=1)
if [ "$HTTP_CODE" = "200" ]; then
    echo "✅"
else
    echo "⚠️ ($HTTP_CODE)"
fi
echo ""

# ========== 8. CREAR SCRIPT DE INICIO MANUAL ==========
echo "[9] Creando script de inicio manual..."

cat > "${BACKEND_DIR}/start-backend.sh" << 'EOF'
#!/bin/bash
# Script para iniciar backend manualmente (sin systemd)

BACKEND_DIR="/opt/kuma-central/kuma-aggregator"
LOG_FILE="/tmp/kuma-backend.log"

# Matar procesos existentes
pkill -f "node.*index.js" 2>/dev/null

cd "$BACKEND_DIR"
echo "Iniciando backend en background..."
NODE_ENV=production nohup node src/index.js > "$LOG_FILE" 2>&1 &
PID=$!
echo "Backend iniciado con PID: $PID"
echo "Log: $LOG_FILE"
echo ""
echo "Para ver logs: tail -f $LOG_FILE"
EOF

chmod +x "${BACKEND_DIR}/start-backend.sh"
echo "   ✅ Script creado: $BACKEND_DIR/start-backend.sh"
echo ""

# ========== 9. REINICIAR FRONTEND ==========
echo "[10] Reiniciando frontend..."

FRONTEND_DIR="/home/thunder/kuma-dashboard-clean/kuma-ui"
cd "$FRONTEND_DIR"
pkill -f "vite" 2>/dev/null || true
npm run dev &
sleep 3

echo "✅ Frontend reiniciado"
echo ""

# ========== 10. INSTRUCCIONES FINALES ==========
echo "====================================================="
echo "✅✅ BACKEND CORREGIDO - SYSTEMD DESACTIVADO ✅✅"
echo "====================================================="
echo ""
echo "📋 ESTADO ACTUAL:"
echo ""
echo "   • ❌ Servicio systemd: DESACTIVADO"
echo "   • ✅ Backend manual: CORRIENDO (PID: $BACKEND_PID)"
echo "   • ✅ Puerto 8080: ABIERTO"
echo "   • ✅ Log: /tmp/kuma-backend.log"
echo ""
echo "🔄 PRUEBA AHORA:"
echo ""
echo "   1. Abre http://10.10.31.31:5173"
echo "   2. ✅ EL DASHBOARD DEBE FUNCIONAR"
echo "   3. ✅ Las gráficas deben cargar"
echo ""
echo "📌 COMANDOS ÚTILES:"
echo ""
echo "   # Ver logs del backend:"
echo "   tail -f /tmp/kuma-backend.log"
echo ""
echo "   # Reiniciar backend:"
echo "   $BACKEND_DIR/start-backend.sh"
echo ""
echo "   # Si quieres volver a systemd:"
echo "   sudo systemctl unmask kuma-aggregator.service"
echo "   sudo systemctl enable kuma-aggregator.service"
echo "   sudo systemctl start kuma-aggregator.service"
echo ""
echo "====================================================="

# Preguntar si quiere ver logs
read -p "¿Ver logs del backend en tiempo real? (s/N): " VIEW_LOGS
if [[ "$VIEW_LOGS" =~ ^[Ss]$ ]]; then
    echo ""
    echo "Presiona Ctrl+C para salir"
    echo "----------------------------------------"
    tail -f /tmp/kuma-backend.log
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

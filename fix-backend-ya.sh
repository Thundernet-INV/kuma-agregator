#!/bin/bash
# fix-backend-ya.sh - ARRANCA EL BACKEND URGENTE

echo "====================================================="
echo "🚨 ARRANCANDO BACKEND - CONEXIÓN REFUSED"
echo "====================================================="

BACKEND_DIR="/opt/kuma-central/kuma-aggregator"
LOG_FILE="/tmp/kuma-backend-urgente.log"

# ========== 1. MATAR PROCESOS ==========
echo ""
echo "[1] Matando procesos existentes..."
pkill -f "node.*index.js" 2>/dev/null && echo "   ✅ Procesos terminados" || echo "   ℹ️ No había procesos"

# ========== 2. IR AL DIRECTORIO ==========
echo ""
echo "[2] Accediendo al backend..."
cd "$BACKEND_DIR" || { 
    echo "❌ No existe $BACKEND_DIR"
    exit 1
}
echo "   ✅ Directorio: $(pwd)"

# ========== 3. VERIFICAR NODE ==========
echo ""
echo "[3] Verificando Node.js..."
NODE_VERSION=$(node --version)
echo "   ✅ Node $NODE_VERSION"

# ========== 4. VERIFICAR ARCHIVOS ==========
echo ""
echo "[4] Verificando archivos críticos..."
if [ -f "src/index.js" ]; then
    echo "   ✅ src/index.js encontrado"
else
    echo "❌ src/index.js NO existe"
    exit 1
fi

# ========== 5. VERIFICAR PUERTO ==========
echo ""
echo "[5] Verificando puerto 8080..."
if ss -tlnp | grep -q ":8080"; then
    OLD_PID=$(ss -tlnp | grep ":8080" | awk -F',' '{print $2}' | awk -F'=' '{print $2}')
    echo "   ⚠️ Puerto ocupado por PID: $OLD_PID"
    kill -9 $OLD_PID 2>/dev/null
    sleep 2
    echo "   ✅ Puerto liberado"
else
    echo "   ✅ Puerto 8080 libre"
fi

# ========== 6. INICIAR BACKEND ==========
echo ""
echo "[6] Iniciando backend..."
cd "$BACKEND_DIR"

# Iniciar con nohup para que corra en background
NODE_ENV=production nohup node src/index.js > "$LOG_FILE" 2>&1 &
BACKEND_PID=$!
echo "   ✅ Backend iniciado con PID: $BACKEND_PID"
echo "   📝 Log: $LOG_FILE"

# ========== 7. ESPERAR ==========
echo ""
echo "[7] Esperando 3 segundos..."
sleep 3

# ========== 8. VERIFICAR PROCESO ==========
echo ""
echo "[8] Verificando proceso..."
if ps -p $BACKEND_PID > /dev/null; then
    echo "   ✅ Proceso vivo (PID: $BACKEND_PID)"
else
    echo "   ❌ El proceso murió"
    echo ""
    echo "=== ÚLTIMAS LÍNEAS DEL LOG ==="
    tail -20 "$LOG_FILE"
    exit 1
fi

# ========== 9. PROBAR LOCAL ==========
echo ""
echo "[9] Probando conexión local..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/health)
if [ "$HTTP_CODE" = "200" ]; then
    echo "   ✅ Backend responde en localhost:8080"
else
    echo "   ❌ Backend NO responde (HTTP $HTTP_CODE)"
    tail -20 "$LOG_FILE"
    exit 1
fi

# ========== 10. PROBAR DESDE IP ==========
echo ""
echo "[10] Probando conexión desde 10.10.31.31..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 http://10.10.31.31:8080/health)
if [ "$HTTP_CODE" = "200" ]; then
    echo "   ✅ Backend responde en 10.10.31.31:8080"
else
    echo "   ❌ Backend NO responde en la IP"
    echo ""
    echo "   🔍 POSIBLES CAUSAS:"
    echo "   1. El backend no está escuchando en 0.0.0.0"
    echo "   2. Firewall bloqueando puerto 8080"
    echo ""
    
    # Verificar bind address
    BIND_ADDR=$(ss -tlnp | grep ":8080" | awk '{print $4}')
    echo "   📍 Bind address: $BIND_ADDR"
    
    if [[ "$BIND_ADDR" == *"127.0.0.1"* ]]; then
        echo "   ❌ Solo escucha en localhost - CORRIGIENDO..."
        
        # Modificar index.js para escuchar en 0.0.0.0
        sed -i 's/app.listen(8080,/app.listen(8080, "0.0.0.0",/' src/index.js
        echo "   ✅ index.js modificado para escuchar en 0.0.0.0"
        
        # Reiniciar
        kill $BACKEND_PID
        sleep 2
        NODE_ENV=production nohup node src/index.js > "$LOG_FILE" 2>&1 &
        BACKEND_PID=$!
        sleep 3
        
        # Probar de nuevo
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://10.10.31.31:8080/health)
        if [ "$HTTP_CODE" = "200" ]; then
            echo "   ✅ AHORA SÍ responde en 10.10.31.31:8080"
        else
            echo "   ❌ Sigue sin responder"
        fi
    fi
    
    # Verificar firewall
    echo ""
    echo "   🔥 Verificando firewall..."
    if command -v ufw &> /dev/null; then
        sudo ufw status | grep -q "8080" || {
            echo "   ⚠️ Puerto 8080 no está abierto en UFW"
            sudo ufw allow 8080/tcp && echo "   ✅ Puerto 8080 abierto en UFW"
        }
    fi
    
    if command -v iptables &> /dev/null; then
        sudo iptables -L -n | grep -q "dpt:8080" || {
            echo "   ⚠️ Puerto 8080 no está abierto en iptables"
            sudo iptables -A INPUT -p tcp --dport 8080 -j ACCEPT && echo "   ✅ Puerto 8080 abierto en iptables"
        }
    fi
fi

# ========== 11. VERIFICAR ENDPOINTS ==========
echo ""
echo "[11] Verificando endpoints críticos..."

echo -n "   • /api/summary: "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://10.10.31.31:8080/api/summary)
if [ "$HTTP_CODE" = "200" ]; then
    echo "✅ (200)"
else
    echo "❌ ($HTTP_CODE)"
fi

echo -n "   • /api/history/series: "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://10.10.31.31:8080/api/history/series)
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "400" ]; then
    echo "✅ ($HTTP_CODE)"
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

# ========== 13. MOSTRAR LOGS ==========
echo ""
echo "====================================================="
echo "📋 ÚLTIMAS LÍNEAS DEL LOG DEL BACKEND:"
echo "====================================================="
tail -20 "$LOG_FILE"
echo "====================================================="

# ========== 14. VERIFICACIÓN FINAL ==========
echo ""
echo "====================================================="
echo "✅✅ VERIFICACIÓN COMPLETADA ✅✅"
echo "====================================================="
echo ""
echo "📊 ESTADO DEL BACKEND:"
echo "   • PID: $BACKEND_PID"
echo "   • Puerto: 8080"
echo "   • Log: $LOG_FILE"
echo ""
echo "🌐 URLS:"
echo "   • Local:  http://localhost:8080"
echo "   • Red:    http://10.10.31.31:8080"
echo ""
echo "🔄 PRUEBA AHORA:"
echo ""
echo "   1. Abre http://10.10.31.31:5173"
echo "   2. EL DASHBOARD DEBE FUNCIONAR"
echo "   3. Si ves el error 'Failed to fetch' - el backend NO está accesible"
echo ""
echo "📌 COMANDOS ÚTILES:"
echo ""
echo "   # Ver logs en tiempo real:"
echo "   tail -f $LOG_FILE"
echo ""
echo "   # Verificar proceso:"
echo "   ps aux | grep node"
echo ""
echo "   # Probar conexión:"
echo "   curl http://10.10.31.31:8080/health"
echo ""
echo "====================================================="

# Preguntar si quiere ver logs
read -p "¿Ver logs en tiempo real? (s/N): " VIEW_LOGS
if [[ "$VIEW_LOGS" =~ ^[Ss]$ ]]; then
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

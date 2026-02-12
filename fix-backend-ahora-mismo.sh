#!/bin/bash
# fix-backend-ahora-mismo.sh - VERIFICAR Y ARRANCAR BACKEND

echo "====================================================="
echo "🔧 VERIFICANDO BACKEND EN 10.10.31.31:8080"
echo "====================================================="

BACKEND_DIR="/opt/kuma-central/kuma-aggregator"
BACKEND_URL="http://10.10.31.31:8080"

# ========== 1. VERIFICAR CONEXIÓN ==========
echo ""
echo "[1] Verificando conectividad con 10.10.31.31:8080..."

if ping -c 1 -W 2 10.10.31.31 > /dev/null 2>&1; then
    echo "   ✅ IP 10.10.31.31 responde ping"
else
    echo "   ⚠️  No responde ping (puede estar bloqueado)"
fi

echo ""
echo "[2] Verificando si el puerto 8080 está abierto..."

if nc -zv 10.10.31.31 8080 2>&1 | grep -q "succeeded\|Connected"; then
    echo "   ✅ Puerto 8080 está abierto"
else
    echo "   ❌ Puerto 8080 NO está abierto"
    NEED_FIX=1
fi

echo ""
echo "[3] Verificando si el backend responde..."

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 http://10.10.31.31:8080/health 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    echo "   ✅ Backend responde (HTTP 200)"
else
    echo "   ❌ Backend NO responde (HTTP $HTTP_CODE)"
    NEED_FIX=1
fi

# ========== 2. SI NO RESPONDE, ARRANCARLO LOCALMENTE ==========
if [ "$NEED_FIX" = "1" ]; then
    echo ""
    echo "====================================================="
    echo "🚨 BACKEND NO RESPONDE - INICIANDO LOCALMENTE"
    echo "====================================================="
    
    # Matar procesos existentes
    echo ""
    echo "[4] Matando procesos node existentes..."
    pkill -f "node.*index.js" 2>/dev/null || true
    pkill -f "node.*kuma-aggregator" 2>/dev/null || true
    sleep 2
    
    # Verificar directorio
    echo ""
    echo "[5] Verificando directorio del backend..."
    if [ ! -d "$BACKEND_DIR" ]; then
        echo "❌ Directorio no encontrado: $BACKEND_DIR"
        exit 1
    fi
    cd "$BACKEND_DIR"
    echo "   ✅ Directorio: $(pwd)"
    
    # Verificar package.json
    echo ""
    echo "[6] Verificando package.json..."
    if [ ! -f "package.json" ]; then
        echo "❌ package.json no encontrado"
        exit 1
    fi
    echo "   ✅ package.json encontrado"
    
    # Instalar dependencias si es necesario
    if [ ! -d "node_modules" ]; then
        echo ""
        echo "[7] Instalando dependencias (esto toma 1 minuto)..."
        npm install
    else
        echo ""
        echo "[7] node_modules existe"
    fi
    
    # Iniciar backend
    echo ""
    echo "[8] Iniciando backend..."
    cd "$BACKEND_DIR"
    NODE_ENV=production nohup node src/index.js > /tmp/kuma-backend.log 2>&1 &
    BACKEND_PID=$!
    echo "   ✅ Backend iniciado con PID: $BACKEND_PID"
    
    # Esperar a que arranque
    echo ""
    echo "[9] Esperando 5 segundos..."
    sleep 5
    
    # Verificar que está corriendo
    if ps -p $BACKEND_PID > /dev/null; then
        echo "   ✅ Proceso vivo"
    else
        echo "   ❌ El proceso murió - revisa logs:"
        tail -20 /tmp/kuma-backend.log
        exit 1
    fi
    
    # Verificar puerto local
    echo ""
    echo "[10] Verificando puerto local 8080..."
    if ss -tlnp | grep -q ":8080"; then
        echo "   ✅ Puerto 8080 escuchando localmente"
    else
        echo "   ❌ Puerto 8080 no está escuchando"
        tail -20 /tmp/kuma-backend.log
        exit 1
    fi
    
    # Verificar health check local
    echo ""
    echo "[11] Verificando health check local..."
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/health)
    if [ "$HTTP_CODE" = "200" ]; then
        echo "   ✅ Backend local responde (HTTP 200)"
    else
        echo "   ❌ Backend local NO responde (HTTP $HTTP_CODE)"
        tail -20 /tmp/kuma-backend.log
        exit 1
    fi
    
    # Verificar summary
    echo ""
    echo "[12] Verificando /api/summary..."
    SUMMARY=$(curl -s http://localhost:8080/api/summary)
    if [ $? -eq 0 ]; then
        INSTANCES=$(echo "$SUMMARY" | grep -o '"instances":\[[^]]*\]' | grep -o 'name":"[^"]*"' | wc -l)
        MONITORS=$(echo "$SUMMARY" | grep -o '"monitors":\[[^]]*\]' | grep -o '{' | wc -l)
        echo "   ✅ Summary OK - $INSTANCES instancias, ~$MONITORS monitores"
    else
        echo "   ❌ Summary falló"
    fi
    
    # ========== 3. VERIFICAR QUE ESCUCHE EN LA IP ==========
    echo ""
    echo "[13] Verificando que escuche en 10.10.31.31..."
    
    # Verificar bind address
    BIND_ADDR=$(ss -tlnp | grep ":8080" | awk '{print $4}')
    if echo "$BIND_ADDR" | grep -q "0.0.0.0"; then
        echo "   ✅ Escuchando en 0.0.0.0:8080 (todas las interfaces)"
    elif echo "$BIND_ADDR" | grep -q "::"; then
        echo "   ✅ Escuchando en [::]:8080 (IPv6 todas interfaces)"
    else
        echo "   ⚠️  Escuchando solo en: $BIND_ADDR"
        echo "   Modificando index.js para escuchar en 0.0.0.0..."
        
        # Modificar index.js para escuchar en 0.0.0.0
        sed -i 's/app.listen(8080,/app.listen(8080, "0.0.0.0",/' "$BACKEND_DIR/src/index.js"
        
        # Reiniciar
        kill $BACKEND_PID
        sleep 2
        cd "$BACKEND_DIR"
        NODE_ENV=production nohup node src/index.js > /tmp/kuma-backend.log 2>&1 &
        sleep 3
        echo "   ✅ Backend reiniciado escuchando en 0.0.0.0"
    fi
    
    # Probar desde la IP
    echo ""
    echo "[14] Probando desde http://10.10.31.31:8080/health..."
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 http://10.10.31.31:8080/health 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
        echo "   ✅ Backend responde en 10.10.31.31:8080"
    else
        echo "   ❌ Backend NO responde en la IP"
        echo ""
        echo "   POSIBLES CAUSAS:"
        echo "   1. Firewall bloqueando puerto 8080"
        echo "   2. NetworkManager/iptables"
        echo ""
        echo "   Verificando firewall:"
        sudo ufw status | grep -q "8080" || echo "   ⚠️  Puerto 8080 no está abierto en firewall"
        sudo iptables -L -n | grep -q "8080" || echo "   ⚠️  iptables podría estar bloqueando"
        
        # Abrir puerto en firewall
        echo ""
        echo "   Abriendo puerto 8080 en firewall..."
        sudo ufw allow 8080/tcp 2>/dev/null || echo "   ⚠️  ufw no disponible"
        sudo iptables -A INPUT -p tcp --dport 8080 -j ACCEPT 2>/dev/null || echo "   ⚠️  iptables no disponible"
    fi
else
    echo ""
    echo "✅ Backend ya está funcionando correctamente"
fi

# ========== 4. REINICIAR FRONTEND ==========
echo ""
echo "[15] Reiniciando frontend..."

FRONTEND_DIR="/home/thunder/kuma-dashboard-clean/kuma-ui"
cd "$FRONTEND_DIR"
pkill -f "vite" 2>/dev/null || true
npm run dev &
sleep 3

# ========== 5. MOSTRAR LOGS ==========
echo ""
echo "====================================================="
echo "📋 ÚLTIMAS LÍNEAS DEL LOG DEL BACKEND:"
echo "====================================================="
tail -20 /tmp/kuma-backend.log 2>/dev/null || echo "No hay log disponible"
echo "====================================================="

echo ""
echo "✅ DIAGNÓSTICO COMPLETADO"
echo ""
echo "📌 PRÓXIMOS PASOS:"
echo ""
echo "   1. Abre http://10.10.31.31:5173 en tu navegador"
echo "   2. Abre la consola (F12) → Red (Network)"
echo "   3. Recarga la página"
echo "   4. Busca peticiones a http://10.10.31.31:8080"
echo "   5. Mira el código de estado que devuelven"
echo ""
echo "   Si ves 'net::ERR_CONNECTION_REFUSED' → El backend NO está accesible desde la IP"
echo "   Si ves '200 OK' pero no hay datos → El backend está funcionando"
echo ""
echo "====================================================="

# Preguntar si quiere ver logs en tiempo real
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

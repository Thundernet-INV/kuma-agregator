#!/bin/bash
echo "🧪 TEST DEL MÓDULO DE HISTORIAL"
echo "================================"

API="http://localhost:8080/api/history"
TS_MS=$(date +%s%3N)
FROM=$((TS_MS - 3600000))  # 1 hora atrás
TO=$TS_MS

echo "1. Probando POST de evento..."
POST_RESP=$(curl -s -X POST "$API" \
  -H "Content-Type: application/json" \
  -d "{
    \"monitorId\": \"test_monitor_$(date +%s)\",
    \"timestamp\": $TS_MS,
    \"status\": \"up\",
    \"responseTime\": 150,
    \"message\": \"Test event\"
  }")

echo "   Respuesta: $POST_RESP"

echo ""
echo "2. Probando GET de eventos..."
GET_RESP=$(curl -s "$API?monitorId=test&from=$FROM&to=$TO&limit=5")
echo "   Respuesta: $GET_RESP"

echo ""
echo "3. Probando GET de series..."
SERIES_RESP=$(curl -s "$API/series?monitorId=test&from=$FROM&to=$TO&bucketMs=60000")
echo "   Respuesta: $(echo $SERIES_RESP | head -c 200)..."

echo ""
echo "4. Verificando base de datos..."
DB_FILE="/opt/kuma-central/kuma-aggregator/data/history.db"
if [ -f "$DB_FILE" ]; then
    echo "   ✅ Base de datos: $DB_FILE"
    if command -v sqlite3 > /dev/null; then
        COUNT=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM monitor_history" 2>/dev/null || echo "0")
        echo "   📊 Registros totales: $COUNT"
        
        echo ""
        echo "5. Últimos 5 registros:"
        sqlite3 "$DB_FILE" "SELECT datetime(timestamp/1000, 'unixepoch'), monitorId, status, responseTime FROM monitor_history ORDER BY timestamp DESC LIMIT 5" 2>/dev/null || echo "   No se pudo leer"
    else
        echo "   ⚠️  sqlite3 no instalado, no se puede verificar datos"
    fi
else
    echo "   ❌ Base de datos no encontrada"
fi

echo ""
echo "================================"
echo "💡 Si ves errores, revisa:"
echo "   - Que el backend esté corriendo: curl http://localhost:8080/health"
echo "   - Los logs del backend"
echo "   - Permisos del directorio data/"

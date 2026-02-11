#!/bin/bash
# diagnosticar-streampool.sh

INSTANCE_IP="10.10.30.123"  # IP de Caracas
API_KEY="uk1_SJENmfv7aYltaADr7a7gkQVx8h5Du33x7nLzCQpj"  # Tu API key de Caracas
MONITOR_NAME="Streampool_CCS_A10"

echo "🔍 DIAGNÓSTICO: ${MONITOR_NAME} en Caracas"
echo "==========================================="
echo

# 1. Verificar directamente en Uptime Kuma
echo "1️⃣ VERIFICANDO EN UPTIME KUMA DIRECTAMENTE"
echo "-------------------------------------------"
curl -s "http://${INSTANCE_IP}:3001/metrics" \
  -u "x:${API_KEY}" \
  | grep -i "streampool\|CCS_A10" | head -20

if [ $? -eq 0 ]; then
    echo "✅ Monitor ENCONTRADO en metrics de Uptime Kuma"
else
    echo "❌ Monitor NO encontrado en metrics de Uptime Kuma"
fi

echo
echo "2️⃣ VERIFICANDO EN BACKEND (STORE)"
echo "-------------------------------------------"
curl -s "http://localhost:8080/api/summary" | \
  jq '.monitors[] | select(.info.monitor_name | contains("Streampool") or contains("CCS_A10"))'

if [ $? -eq 0 ] && [ $(curl -s "http://localhost:8080/api/summary" | jq '.monitors[] | select(.info.monitor_name | contains("Streampool"))' | wc -l) -gt 0 ]; then
    echo "✅ Monitor ENCONTRADO en store"
else
    echo "❌ Monitor NO encontrado en store"
fi

echo
echo "3️⃣ VERIFICANDO EN BACKEND (SQLITE)"
echo "-------------------------------------------"
curl -s "http://localhost:8080/api/metric-history/monitors" | \
  jq '.monitors[] | select(.monitorName | contains("Streampool") or contains("CCS_A10"))'

echo
echo "4️⃣ VERIFICANDO LOGS DEL BACKEND"
echo "-------------------------------------------"
sudo journalctl -u kuma-aggregator.service --since "1 minute ago" | grep -i "streampool\|CCS_A10" || echo "No hay logs recientes"

echo
echo "5️⃣ VERIFICANDO TIPO DE MONITOR"
echo "-------------------------------------------"
echo "Streampool suele ser un monitor de tipo 'push' o 'stream'"
echo "Estos NO son compatibles con /metrics por defecto"

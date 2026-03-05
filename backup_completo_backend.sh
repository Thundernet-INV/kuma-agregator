#!/bin/bash
# backup_completo_backend.sh
# Crea un backup completo del backend funcional antes de hacer cambios

echo "====================================================="
echo "📦 CREANDO BACKUP COMPLETO DEL BACKEND FUNCIONAL"
echo "====================================================="

BACKEND_DIR="/opt/kuma-central/kuma-aggregator"
BACKUP_NAME="backend_funcionando_antes_de_empezar"
BACKUP_DIR="/root/backups/${BACKUP_NAME}_$(date +%Y%m%d_%H%M%S)"

# ========== 1. CREAR DIRECTORIO DE BACKUP ==========
echo ""
echo "[1] Creando directorio de backup..."
mkdir -p "$BACKUP_DIR"
mkdir -p "$BACKUP_DIR/data"
mkdir -p "$BACKUP_DIR/src"
mkdir -p "$BACKUP_DIR/scripts"
mkdir -p "$BACKUP_DIR/logs"

echo "✅ Directorio creado: $BACKUP_DIR"

# ========== 2. RESPALDAR ARCHIVOS DE CONFIGURACIÓN ==========
echo ""
echo "[2] Respaldando archivos de configuración..."

cp "$BACKEND_DIR/package.json" "$BACKUP_DIR/" 2>/dev/null || echo "⚠️ package.json no encontrado"
cp "$BACKEND_DIR/instances.json" "$BACKUP_DIR/" 2>/dev/null || echo "⚠️ instances.json no encontrado"
cp "$BACKEND_DIR/.env" "$BACKUP_DIR/" 2>/dev/null || echo "⚠️ .env no encontrado"

echo "✅ Configuración respaldada"

# ========== 3. RESPALDAR BASE DE DATOS ==========
echo ""
echo "[3] Respaldando base de datos..."

# Detener el backend temporalmente para backup consistente
BACKEND_PID=$(ps aux | grep "node.*index.js" | grep -v grep | awk '{print $2}')
if [ -n "$BACKEND_PID" ]; then
    echo "   ⏸️ Pausando backend (PID: $BACKEND_PID)..."
    kill -STOP $BACKEND_PID
    sleep 2
fi

# Copiar archivos de base de datos
if [ -f "$BACKEND_DIR/data/history.db" ]; then
    cp "$BACKEND_DIR/data/history.db" "$BACKUP_DIR/data/"
    echo "   ✅ history.db copiado"
else
    echo "   ⚠️ history.db no encontrado"
fi

if [ -f "$BACKEND_DIR/data/history.db-shm" ]; then
    cp "$BACKEND_DIR/data/history.db-shm" "$BACKUP_DIR/data/" 2>/dev/null
fi

if [ -f "$BACKEND_DIR/data/history.db-wal" ]; then
    cp "$BACKEND_DIR/data/history.db-wal" "$BACKUP_DIR/data/" 2>/dev/null
fi

# Reanudar backend
if [ -n "$BACKEND_PID" ]; then
    echo "   ▶️ Reanudando backend..."
    kill -CONT $BACKEND_PID
fi

echo "✅ Base de datos respaldada"

# ========== 4. RESPALDAR CÓDIGO FUENTE ==========
echo ""
echo "[4] Respaldando código fuente..."

# Respaldar archivos principales
cp "$BACKEND_DIR/src/index.js" "$BACKUP_DIR/src/" 2>/dev/null
cp "$BACKEND_DIR/src/poller.js" "$BACKUP_DIR/src/" 2>/dev/null
cp "$BACKEND_DIR/src/store.js" "$BACKUP_DIR/src/" 2>/dev/null
cp "$BACKEND_DIR/src/metricsParser.js" "$BACKUP_DIR/src/" 2>/dev/null

# Respaldar servicios
mkdir -p "$BACKUP_DIR/src/services"
cp -r "$BACKEND_DIR/src/services/"* "$BACKUP_DIR/src/services/" 2>/dev/null

# Respaldar rutas
mkdir -p "$BACKUP_DIR/src/routes"
cp -r "$BACKEND_DIR/src/routes/"* "$BACKUP_DIR/src/routes/" 2>/dev/null

# Respaldar controladores
mkdir -p "$BACKUP_DIR/src/controllers"
cp -r "$BACKEND_DIR/src/controllers/"* "$BACKUP_DIR/src/controllers/" 2>/dev/null

# Respaldar scripts
cp -r "$BACKEND_DIR/scripts/"* "$BACKUP_DIR/scripts/" 2>/dev/null

echo "✅ Código fuente respaldado"

# ========== 5. RESPALDAR LOGS ==========
echo ""
echo "[5] Respaldando logs..."

if [ -f "/tmp/kuma-backend.log" ]; then
    cp "/tmp/kuma-backend.log" "$BACKUP_DIR/logs/"
    echo "   ✅ Log copiado"
fi

if [ -f "/var/log/kuma-backend.log" ]; then
    cp "/var/log/kuma-backend.log" "$BACKUP_DIR/logs/" 2>/dev/null
fi

# ========== 6. CREAR INFORMACIÓN DEL BACKUP ==========
echo ""
echo "[6] Creando archivo de información..."

cat > "$BACKUP_DIR/README.txt" << EOF
BACKUP DEL BACKEND FUNCIONAL
=============================
Fecha: $(date)
Directorio original: $BACKEND_DIR

ESTADO ANTES DE MODIFICACIONES:
- Backend funcional con promedios de instancia
- Endpoints de combustible funcionando
- Base de datos con datos históricos

CONTENIDO:
- /data/      : Base de datos SQLite
- /src/       : Código fuente completo
- /scripts/   : Scripts de utilidad
- /logs/      : Logs del sistema

PARA RESTAURAR:
./restaurar_backend.sh $BACKUP_DIR
EOF

echo "✅ Información guardada"

# ========== 7. CREAR SCRIPT DE RESTAURACIÓN ==========
echo ""
echo "[7] Creando script de restauración..."

cat > "$BACKUP_DIR/../restaurar_backend.sh" << 'EOF'
#!/bin/bash
# restaurar_backend.sh
# Script para restaurar backend desde backup

if [ -z "$1" ]; then
    echo "Uso: $0 <directorio_backup>"
    exit 1
fi

BACKUP_DIR="$1"
BACKEND_DIR="/opt/kuma-central/kuma-aggregator"

echo "====================================================="
echo "🔄 RESTAURANDO BACKEND DESDE: $BACKUP_DIR"
echo "====================================================="

# Detener backend
echo ""
echo "[1] Deteniendo backend..."
pkill -f "node.*index.js" 2>/dev/null
sleep 3

# Crear backup del estado actual por si acaso
CURRENT_BACKUP="/root/backups/estado_anterior_restauracion_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$CURRENT_BACKUP"
cp -r "$BACKEND_DIR"/* "$CURRENT_BACKUP/" 2>/dev/null
echo "✅ Backup del estado actual guardado en: $CURRENT_BACKUP"

# Restaurar archivos
echo ""
echo "[2] Restaurando archivos..."

# Restaurar configuración
cp "$BACKUP_DIR/package.json" "$BACKEND_DIR/" 2>/dev/null
cp "$BACKUP_DIR/instances.json" "$BACKEND_DIR/" 2>/dev/null
cp "$BACKUP_DIR/.env" "$BACKEND_DIR/" 2>/dev/null

# Restaurar base de datos
if [ -f "$BACKUP_DIR/data/history.db" ]; then
    cp "$BACKUP_DIR/data/history.db" "$BACKEND_DIR/data/"
    echo "   ✅ Base de datos restaurada"
fi

# Restaurar código fuente
cp -r "$BACKUP_DIR/src/"* "$BACKEND_DIR/src/" 2>/dev/null
cp -r "$BACKUP_DIR/scripts/"* "$BACKEND_DIR/scripts/" 2>/dev/null

echo "✅ Archivos restaurados"

# Instalar dependencias si es necesario
echo ""
echo "[3] Verificando dependencias..."
cd "$BACKEND_DIR"
if [ ! -d "node_modules" ]; then
    echo "   Instalando dependencias..."
    npm install
else
    echo "   ✅ node_modules existe"
fi

# Iniciar backend
echo ""
echo "[4] Iniciando backend..."
cd "$BACKEND_DIR"
NODE_ENV=production nohup node src/index.js > /tmp/kuma-backend.log 2>&1 &
sleep 5

# Verificar que está corriendo
BACKEND_PID=$(ps aux | grep "node.*index.js" | grep -v grep | awk '{print $2}')
if [ -n "$BACKEND_PID" ]; then
    echo "✅ Backend iniciado con PID: $BACKEND_PID"
    
    # Probar endpoints
    echo ""
    echo "[5] Probando endpoints..."
    
    curl -s "http://localhost:8080/health" | grep -q "ok" && echo "   ✅ /health OK"
    curl -s "http://localhost:8080/api/summary" | grep -q "success" && echo "   ✅ /api/summary OK"
    curl -s "http://localhost:8080/api/instance/averages/Caracas?hours=1" | grep -q "success" && echo "   ✅ /api/instance/averages OK"
else
    echo "❌ Error iniciando backend"
    tail -20 /tmp/kuma-backend.log
fi

echo ""
echo "====================================================="
echo "✅ RESTAURACIÓN COMPLETADA"
echo "====================================================="
echo "Logs: tail -f /tmp/kuma-backend.log"
EOF

chmod +x "$BACKUP_DIR/../restaurar_backend.sh"
echo "✅ Script de restauración creado: restaurar_backend.sh"

# ========== 8. COMPRIMIR BACKUP ==========
echo ""
echo "[8] Comprimiendo backup..."

cd "$BACKUP_DIR/.."
tar -czf "${BACKUP_NAME}_$(date +%Y%m%d_%H%M%S).tar.gz" "$(basename "$BACKUP_DIR")"
echo "✅ Backup comprimido"

# ========== 9. MOSTRAR INFORMACIÓN ==========
echo ""
echo "====================================================="
echo "✅✅ BACKUP COMPLETADO EXITOSAMENTE ✅✅"
echo "====================================================="
echo ""
echo "📋 INFORMACIÓN DEL BACKUP:"
echo ""
echo "   📁 Directorio: $BACKUP_DIR"
echo "   📦 Comprimido: ${BACKUP_NAME}_$(date +%Y%m%d_%H%M%S).tar.gz"
echo ""
echo "📦 CONTENIDO:"
echo "   • ✅ Base de datos: $(du -sh "$BACKUP_DIR/data" 2>/dev/null | cut -f1 || echo '0B')"
echo "   • ✅ Código fuente: $(du -sh "$BACKUP_DIR/src" 2>/dev/null | cut -f1 || echo '0B')"
echo "   • ✅ Configuración: $(ls -1 "$BACKUP_DIR"/*.json 2>/dev/null | wc -l) archivos"
echo ""
echo "🔄 PARA RESTAURAR:"
echo ""
echo "   ./restaurar_backend.sh $BACKUP_DIR"
echo ""
echo "====================================================="

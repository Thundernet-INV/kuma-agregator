echo "🧹 Limpiando monitores fantasma..."
sqlite3 /opt/kuma-central/kuma-aggregator/data/history.db <<EOF
-- Ver monitores inactivos (>10 min)
SELECT monitorId, datetime(lastSeen/1000, 'unixepoch') as lastSeen 
FROM active_monitors 
WHERE lastSeen < strftime('%s','now')*1000 - 600000;

-- Eliminar inactivos
DELETE FROM active_monitors 
WHERE lastSeen < strftime('%s','now')*1000 - 600000;

SELECT 'Eliminados: ' || changes() || ' monitores';

-- OPCIÓN EXTREMA (solo si quieres eliminar TODO):
-- DELETE FROM monitor_history WHERE monitorId NOT IN (SELECT monitorId FROM active_monitors);
-- .quit
EOF

echo "✅ Limpieza completada"

#!/bin/bash

echo "🔧 Agregando CORS al backend..."

# Buscar línea de cors()
LINE=$(grep -n "app.use(cors())" src/index.js | cut -d: -f1)

if [ -n "$LINE" ]; then
  # Reemplazar cors() simple por cors configurado
  sed -i "${LINE}c\\
app.use(cors({\\
  origin: ['http://localhost:5174', 'http://localhost:5173', 'http://10.10.31.31:5174', 'http://10.10.31.31:5173', 'http://10.10.31.31'],\\
  credentials: true,\\
  methods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'],\\
  allowedHeaders: ['Content-Type', 'Authorization']\\
}));" src/index.js
  
  echo "✅ CORS agregado en línea $LINE"
else
  echo "❌ No se encontró app.use(cors())"
  exit 1
fi

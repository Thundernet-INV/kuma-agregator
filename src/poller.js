// /opt/kuma-central/kuma-aggregator/src/poller.js
import axios from "axios";
import { parsePromText } from "./metricsParser.js";

// Cache para guardar los datos de monitores (incluyendo tags)
const monitorsCache = new Map(); // instance.name -> { timestamp, data }

export async function pollInstance(instance) {
  // Obtener métricas numéricas del endpoint /metrics (como antes)
  const metricsRes = await axios.get(instance.baseUrl + "/metrics", {
    auth: { username: "x", password: instance.apiKey },
    timeout: 5000
  });
  
  const metrics = parsePromText(metricsRes.data);
  
  // Obtener datos completos de monitores (incluyendo tags) del endpoint API
  let monitorsData = [];
  try {
    // Verificar si tenemos datos en caché (menos de 5 minutos)
    const cached = monitorsCache.get(instance.name);
    if (cached && (Date.now() - cached.timestamp) < 300000) {
      monitorsData = cached.data;
    } else {
      const apiRes = await axios.get(instance.baseUrl + "/api/monitors", {
        headers: { 
          'Authorization': `Bearer ${instance.apiKey}`,
          'Accept': 'application/json'
        },
        timeout: 5000
      });
      
      if (apiRes.data && Array.isArray(apiRes.data)) {
        monitorsData = apiRes.data;
        monitorsCache.set(instance.name, {
          timestamp: Date.now(),
          data: monitorsData
        });
        console.log(`✅ Cache actualizado para ${instance.name}: ${monitorsData.length} monitores`);
      }
    }
  } catch (error) {
    console.error(`Error obteniendo API de ${instance.name}:`, error.message);
    // Si falla, continuamos sin tags (usamos datos de caché si existen)
  }
  
  // Crear mapa de tags por nombre de monitor
  const tagsMap = new Map();
  for (const m of monitorsData) {
    if (m.name) {
      tagsMap.set(m.name.trim(), {
        tags: m.tags || [],
        url: m.url,
        hostname: m.hostname
      });
    }
  }
  
  return { metrics, tagsMap };
}

export function extract(series) {
  const { metrics, tagsMap } = series; // Ahora series incluye metrics y tagsMap
  const map = new Map();

  for (const s of metrics) {
    if (!s.labels.monitor_name) continue;
    
    // Limpiar nombre (quitar espacios)
    const name = s.labels.monitor_name.trim();
    
    if (!map.has(name)) {
      // Obtener el tipo de monitor
      const type = s.labels.monitor_type || 'unknown';
      
      // Obtener tags del mapa (si existen)
      const monitorInfo = tagsMap.get(name) || {};
      const tags = monitorInfo.tags || [];
      
      // Guardar hostname
      const hostname = s.labels.monitor_hostname && s.labels.monitor_hostname !== 'null' 
        ? s.labels.monitor_hostname 
        : monitorInfo.hostname || null;
      
      // Para PING: usar hostname como URL
      let displayUrl = s.labels.monitor_url || monitorInfo.url || '';
      if (type === 'ping' && hostname) {
        displayUrl = hostname;
      }

      map.set(name, { 
        info: {
          monitor_name: name,
          monitor_type: type,
          monitor_url: displayUrl,
          monitor_hostname: hostname,
          monitor_port: s.labels.monitor_port,
          tags: tags // Incluimos las tags
        },
        latest: {}
      });
    }
    
    const entry = map.get(name);
    if (s.metric === "monitor_status") entry.latest.status = Number(s.value);
    if (s.metric === "monitor_response_time") entry.latest.responseTime = Number(s.value);
  }
  
  return [...map.values()];
}

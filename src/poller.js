// src/poller.js - VERSIÓN CORREGIDA CON SOPORTE PARA PING
import axios from "axios";
import { parsePromText } from "./metricsParser.js";

export async function pollInstance(instance) {
  const res = await axios.get(instance.baseUrl + "/metrics", {
    auth: { username: "x", password: instance.apiKey },
    timeout: 5000
  });
  return parsePromText(res.data);
}

export function extract(series) {
  const map = new Map();

  for (const s of series) {
    if (!s.labels.monitor_name) continue;
    
    // Limpiar nombre (quitar espacios)
    const name = s.labels.monitor_name.trim();
    
    if (!map.has(name)) {
      // Obtener el tipo de monitor
      const type = s.labels.monitor_type || 'unknown';
      
      // 🟢 IMPORTANTE: Guardar el hostname para monitores PING
      const hostname = s.labels.monitor_hostname && s.labels.monitor_hostname !== 'null' 
        ? s.labels.monitor_hostname 
        : null;
      
      // Para PING: usar hostname como URL
      let displayUrl = s.labels.monitor_url || '';
      if (type === 'ping' && hostname) {
        displayUrl = hostname;  // 👈 ESTO ES LO QUE FALTABA
      }

      map.set(name, { 
        info: {
          monitor_name: name,
          monitor_type: type,
          monitor_url: displayUrl,
          monitor_hostname: hostname,  // 👈 GUARDAR EXPLÍCITAMENTE
          monitor_port: s.labels.monitor_port
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

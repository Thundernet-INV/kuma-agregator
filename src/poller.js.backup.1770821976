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
    const name = s.labels.monitor_name;
    if (!map.has(name)) map.set(name, { 
      info: {
        monitor_name: name,
        monitor_type: s.labels.monitor_type,
        monitor_url: s.labels.monitor_url
      },
      latest: {}
    });
    const entry = map.get(name);

    if (s.metric === "monitor_status") entry.latest.status = Number(s.value);
    if (s.metric === "monitor_response_time") entry.latest.responseTime = Number(s.value);
  }
  return [...map.values()];
}

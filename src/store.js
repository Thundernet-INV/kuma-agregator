// store.js - patched
export class Store {
  constructor() {
    this.instances = new Map();
    this.monitors  = new Map();
    this.subscribers = new Set();
  }

  // Clave robusta TEMPORAL mientras no usemos monitorId nativo
  static keyOf(m) {
    const i = m.instance;
    const t = m.info?.monitor_type ?? '';
    const u = m.info?.monitor_url  ?? '';
    const n = m.info?.monitor_name ?? '';
    return `${i}\n${t}\n${u}\n${n}`;
  }

  upsertInstance(name, ok) {
    this.instances.set(name, { name, ok, ts: Date.now() });
  }

  upsertMonitor(instance, m) {
    const key = Store.keyOf({ instance, ...m });
    this.monitors.set(key, { instance, ...m });
  }

  // Reemplazo total del snapshot -> elimina huérfanos
  replaceSnapshot(next) {
    const nextInstances = new Map();
    for (const i of next.instances) {
      nextInstances.set(i.name, { ...i, ts: Date.now() });
    }
    const nextMonitors = new Map();
    for (const m of next.monitors) {
      nextMonitors.set(Store.keyOf(m), m);
    }
    this.instances = nextInstances;
    this.monitors  = nextMonitors;
  }

  snapshot() {
    return {
      instances: [...this.instances.values()],
      monitors:  [...this.monitors.values()],
    };
  }

  broadcast(ev, data) {
    const payload = `event: ${ev}\ndata: ${JSON.stringify(data)}\n\n`;
    for (const res of this.subscribers) res.write(payload);
  }
}

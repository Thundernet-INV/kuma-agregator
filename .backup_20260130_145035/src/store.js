export class Store {
  constructor() { 
    this.instances = new Map();
    this.monitors = new Map();
    this.subscribers = new Set();
  }

  upsertInstance(name, ok) {
    this.instances.set(name, { name, ok, ts: Date.now() });
  }

  upsertMonitor(instance, m) {
    const key = instance + "|" + m.info.monitor_name;
    this.monitors.set(key, { instance, ...m });
  }

  snapshot() {
    return {
      instances: [...this.instances.values()],
      monitors: [...this.monitors.values()]
    };
  }

  broadcast(ev, data) {
    const payload = `event: ${ev}\ndata: ${JSON.stringify(data)}\n\n`;
    for (const res of this.subscribers) res.write(payload);
  }
}

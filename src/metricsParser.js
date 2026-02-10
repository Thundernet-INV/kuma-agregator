export function parsePromText(text) {
  const lines = text.split('\n').filter(l => l && !l.startsWith('#'));
  const out = [];

  for (const line of lines) {
    const m = line.match(/^([a-zA-Z0-9_:]+)(\{([^}]*)\})?\s+(-?\d+(\.\d+)?)/);
    if (!m) continue;

    const metric = m[1];
    const labels = {};
    if (m[3]) {
      m[3].split(',').forEach(kv => {
        const [k,v] = kv.split('=');
        labels[k] = v.replace(/"/g,'');
      });
    }

    out.push({ metric, labels, value: Number(m[4]) });
  }
  return out;
}

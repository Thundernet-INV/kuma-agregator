import express from "express";
import cors from "cors";
import fs from "fs";

import { Store } from "./store.js";
import { pollInstance, extract } from "./poller.js";

const instances = JSON.parse(fs.readFileSync("./instances.json","utf-8"));
const app = express();
app.use(cors());

const store = new Store();

async function cycle() {
  for (const inst of instances) {
    try {
      const series = await pollInstance(inst);
      const extracted = extract(series);
      store.upsertInstance(inst.name, true);
      extracted.forEach(m => store.upsertMonitor(inst.name, m));
    } catch {
      store.upsertInstance(inst.name, false);
    }
  }
  store.broadcast("tick", store.snapshot());
}

setInterval(cycle, 5000);
cycle();

// API
app.get("/api/summary", (req, res) => res.json(store.snapshot()));
app.get("/api/stream", (req, res) => {
  res.set({
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    "Connection": "keep-alive"
  });
  res.flushHeaders();
  store.subscribers.add(res);
  req.on("close",()=>store.subscribers.delete(res));
});

app.listen(8080,()=>console.log("Aggregator on 8080"));

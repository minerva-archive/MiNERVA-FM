// MiNERVA-FM metadata bridge — zero-dependency Node (>=18).
// - GET  /events       : Server-Sent Events feed of the current now-playing JSON
// - GET  /now-playing  : Current track as plain JSON (for bots, embeds, etc.)
// - POST /update       : Radio host pushes a new track (Bearer-token protected)
// - POST /admin/skip   : Skip the current track    (Bearer-token protected)
// Listener count is derived from the number of active SSE connections.
//
// Env: BRIDGE_PORT (8088), BRIDGE_TOKEN
import http           from "node:http";
import { execSync }   from "node:child_process";
import { readFileSync } from "node:fs";

const PORT  = Number(process.env.BRIDGE_PORT || 8088);
const TOKEN = process.env.BRIDGE_TOKEN || "change-me";

let current = {
  source: "ON AIR", id: "—", platform: "",
  game: "", track: "", scheme: "minerva", char: "#", listeners: 0,
};
const clients = new Set();

function broadcast() {
  const payload = `data: ${JSON.stringify(current)}\n\n`;
  for (const res of clients) { try { res.write(payload); } catch {} }
}

function updateListeners() {
  const n = clients.size;
  if (n !== current.listeners) { current.listeners = n; broadcast(); }
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://localhost");

  // ── SSE feed ──────────────────────────────────────────────────────────────
  if (req.method === "GET" && url.pathname === "/events") {
    res.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      "Connection":    "keep-alive",
      "Access-Control-Allow-Origin": "*",
    });
    res.write("retry: 3000\n\n");
    res.write(`data: ${JSON.stringify(current)}\n\n`);
    clients.add(res);
    updateListeners();
    const ka = setInterval(() => { try { res.write(": ping\n\n"); } catch {} }, 25000);
    req.on("close", () => { clearInterval(ka); clients.delete(res); updateListeners(); });
    return;
  }

  // ── Now-playing snapshot (for Discord bot status, site embed, etc.) ───────
  if (req.method === "GET" && url.pathname === "/now-playing") {
    res.writeHead(200, {
      "Content-Type":  "application/json",
      "Cache-Control": "no-store",
      "Access-Control-Allow-Origin": "*",
    });
    res.end(JSON.stringify(current));
    return;
  }

  // ── Track update (pushed by station.sh) ───────────────────────────────────
  if (req.method === "POST" && url.pathname === "/update") {
    if (req.headers.authorization !== `Bearer ${TOKEN}`) { res.writeHead(401).end("unauthorized"); return; }
    let body = "";
    req.on("data", c => { body += c; if (body.length > 1e5) req.destroy(); });
    req.on("end", () => {
      try {
        const m = JSON.parse(body);
        current = { ...current, ...m, source: "ON AIR" };
        broadcast();
        res.writeHead(204).end();
      } catch { res.writeHead(400).end("bad json"); }
    });
    return;
  }

  // ── Admin: skip current track ─────────────────────────────────────────────
  if (req.method === "POST" && url.pathname === "/admin/skip") {
    if (req.headers.authorization !== `Bearer ${TOKEN}`) { res.writeHead(401).end("unauthorized"); return; }
    try {
      const pid = readFileSync("/tmp/station.pid", "utf8").trim();
      execSync(`kill -USR1 ${pid}`);
      res.writeHead(204).end();
    } catch (e) {
      console.error("skip failed:", e.message);
      res.writeHead(500).end("skip failed");
    }
    return;
  }

  res.writeHead(404).end("not found");
});
server.listen(PORT, () => console.log(`metadata bridge: SSE /events, GET /now-playing, POST /update, POST /admin/skip on :${PORT}`));

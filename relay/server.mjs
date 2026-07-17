// Pedals relay — protocol v1 §1.
//
// Zero-knowledge WebSocket relay: forwards binary frames verbatim between the
// single `host` and single `client` of a room. Never inspects, never persists,
// never logs payloads.

import { createServer } from "node:http";
import { pathToFileURL } from "node:url";
import { WebSocketServer, WebSocket } from "ws";

const ROOM_PATH = /^\/v1\/room\/([0-9a-f]{32})$/;
const ROLES = new Set(["host", "client"]);
const PING_INTERVAL_MS = 30_000;
const CLOSE_REPLACED = 4000;

export function createRelay() {
  // roomId -> { host: WebSocket|null, client: WebSocket|null }
  const rooms = new Map();
  const wss = new WebSocketServer({ noServer: true });

  const server = createServer((req, res) => {
    const { pathname } = new URL(req.url, "http://relay.invalid");
    if ((req.method === "GET" || req.method === "HEAD") && pathname === "/healthz") {
      res.writeHead(200, { "content-type": "text/plain; charset=utf-8" });
      res.end("ok");
      return;
    }
    res.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
    res.end("not found");
  });

  server.on("upgrade", (req, socket, head) => {
    const url = new URL(req.url, "http://relay.invalid");
    const match = ROOM_PATH.exec(url.pathname);
    const role = url.searchParams.get("role");
    if (!match || !ROLES.has(role)) {
      socket.write("HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
      socket.destroy();
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => join(match[1], role, ws));
  });

  function join(roomId, role, ws) {
    let room = rooms.get(roomId);
    if (!room) {
      room = { host: null, client: null };
      rooms.set(roomId, room);
    }

    // Replace-on-rejoin: the newest connection per role wins.
    const previous = room[role];
    room[role] = ws;
    if (previous) previous.close(CLOSE_REPLACED, "replaced by new connection");

    const peerRole = role === "host" ? "client" : "host";

    ws.isAlive = true;
    ws.on("pong", () => {
      ws.isAlive = true;
    });

    ws.on("message", (data, isBinary) => {
      if (!isBinary) return; // text frames are ignored per spec
      const peer = room[peerRole];
      if (peer && peer.readyState === WebSocket.OPEN) {
        peer.send(data, { binary: true });
      }
      // Peer absent: drop (no queueing) — both ends resync via attach/replay.
    });

    ws.on("close", () => {
      if (room[role] === ws) {
        room[role] = null;
        if (!room.host && !room.client) rooms.delete(roomId);
      }
    });

    ws.on("error", () => {
      ws.terminate();
    });
  }

  const heartbeat = setInterval(() => {
    for (const ws of wss.clients) {
      if (!ws.isAlive) {
        ws.terminate();
        continue;
      }
      ws.isAlive = false;
      ws.ping();
    }
  }, PING_INTERVAL_MS);
  heartbeat.unref();

  server.on("close", () => {
    clearInterval(heartbeat);
    for (const ws of wss.clients) ws.terminate();
    wss.close();
  });

  return server;
}

const isMain =
  process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;

if (isMain) {
  const port = Number(process.env.PORT ?? 8787);
  const server = createRelay();
  server.listen(port, () => {
    console.log(`pedals-relay listening on :${server.address().port}`);
  });
}

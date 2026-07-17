import test from "node:test";
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { once } from "node:events";
import WebSocket from "ws";
import { createRelay } from "../server.mjs";

const ROOM_A = "0123456789abcdef0123456789abcdef";
const ROOM_B = "fedcba9876543210fedcba9876543210";

let server;
let base; // http://127.0.0.1:<port>
let wsBase; // ws://127.0.0.1:<port>

test.before(async () => {
  server = createRelay();
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const { port } = server.address();
  base = `http://127.0.0.1:${port}`;
  wsBase = `ws://127.0.0.1:${port}`;
});

test.after(async () => {
  server.close();
  await once(server, "close");
});

function connect(room, role) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${wsBase}/v1/room/${room}?role=${role}`);
    ws.once("open", () => resolve(ws));
    ws.once("error", reject);
  });
}

function nextMessage(ws, timeoutMs = 2000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error("timed out waiting for message")),
      timeoutMs,
    );
    ws.once("message", (data, isBinary) => {
      clearTimeout(timer);
      resolve({ data, isBinary });
    });
  });
}

function closed(ws, timeoutMs = 2000) {
  return new Promise((resolve, reject) => {
    if (ws.readyState === WebSocket.CLOSED) {
      // Already closed; code/reason were lost — resolve with what we can.
      resolve({ code: undefined, reason: undefined });
      return;
    }
    const timer = setTimeout(
      () => reject(new Error("timed out waiting for close")),
      timeoutMs,
    );
    ws.once("close", (code, reason) => {
      clearTimeout(timer);
      resolve({ code, reason: reason.toString() });
    });
  });
}

/** Assert no message arrives on ws within `ms`. */
async function assertSilent(ws, ms = 200) {
  await assert.rejects(nextMessage(ws, ms), /timed out/);
}

function closeAll(...sockets) {
  for (const ws of sockets) {
    if (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING) {
      ws.close();
    }
  }
}

test("GET /healthz returns 200 ok", async () => {
  const res = await fetch(`${base}/healthz`);
  assert.equal(res.status, 200);
  assert.equal(await res.text(), "ok");
});

test("unknown HTTP paths return 404", async () => {
  const res = await fetch(`${base}/v1/room/${ROOM_A}`);
  assert.equal(res.status, 404);
});

test("upgrade is rejected for bad roomId or role", async () => {
  for (const path of [
    `/v1/room/not-hex?role=host`,
    `/v1/room/0123456789abcdef?role=host`, // too short
    `/v1/room/${ROOM_A.toUpperCase()}?role=host`, // uppercase not allowed
    `/v1/room/${ROOM_A}?role=server`,
    `/v1/room/${ROOM_A}`, // missing role
  ]) {
    await assert.rejects(
      new Promise((resolve, reject) => {
        const ws = new WebSocket(`${wsBase}${path}`);
        ws.once("open", () => resolve(ws));
        ws.once("error", reject);
      }),
      /400/,
      `expected 400 for ${path}`,
    );
  }
});

test("forwards binary verbatim in both directions", async () => {
  const host = await connect(ROOM_A, "host");
  const client = await connect(ROOM_A, "client");
  try {
    const h2c = randomBytes(64 * 1024);
    const c2h = randomBytes(3); // small frame too
    host.send(h2c);
    const got1 = await nextMessage(client);
    assert.equal(got1.isBinary, true);
    assert.ok(Buffer.from(got1.data).equals(h2c), "host->client bytes intact");

    client.send(c2h);
    const got2 = await nextMessage(host);
    assert.equal(got2.isBinary, true);
    assert.ok(Buffer.from(got2.data).equals(c2h), "client->host bytes intact");
  } finally {
    closeAll(host, client);
  }
});

test("text frames are ignored, not forwarded", async () => {
  const host = await connect(ROOM_A, "host");
  const client = await connect(ROOM_A, "client");
  try {
    host.send("this is text and must be dropped");
    const marker = randomBytes(16);
    host.send(marker);
    const got = await nextMessage(client);
    assert.equal(got.isBinary, true);
    assert.ok(Buffer.from(got.data).equals(marker), "first delivery is the binary frame");
  } finally {
    closeAll(host, client);
  }
});

test("messages sent while peer is absent are dropped, not queued", async () => {
  const host = await connect(ROOM_A, "host");
  try {
    host.send(randomBytes(32)); // no client yet -> dropped
    const client = await connect(ROOM_A, "client");
    try {
      await assertSilent(client); // nothing queued
      const live = randomBytes(32);
      host.send(live);
      const got = await nextMessage(client);
      assert.ok(Buffer.from(got.data).equals(live), "only post-join traffic arrives");
    } finally {
      closeAll(client);
    }
  } finally {
    closeAll(host);
  }
});

test("new client replaces the previous client", async () => {
  const host = await connect(ROOM_A, "host");
  const client1 = await connect(ROOM_A, "client");
  const client2 = await connect(ROOM_A, "client");
  try {
    const { code } = await closed(client1);
    assert.equal(code, 4000, "old client closed with replaced code");

    const msg = randomBytes(32);
    host.send(msg);
    const got = await nextMessage(client2);
    assert.ok(Buffer.from(got.data).equals(msg), "traffic goes to the new client");

    const up = randomBytes(8);
    client2.send(up);
    const gotUp = await nextMessage(host);
    assert.ok(Buffer.from(gotUp.data).equals(up), "new client can send to host");
  } finally {
    closeAll(host, client2);
  }
});

test("new host replaces the previous host", async () => {
  const host1 = await connect(ROOM_A, "host");
  const client = await connect(ROOM_A, "client");
  const host2 = await connect(ROOM_A, "host");
  try {
    const { code } = await closed(host1);
    assert.equal(code, 4000, "old host closed with replaced code");

    const msg = randomBytes(32);
    client.send(msg);
    const got = await nextMessage(host2);
    assert.ok(Buffer.from(got.data).equals(msg), "traffic goes to the new host");
  } finally {
    closeAll(client, host2);
  }
});

test("peer disconnect leaves the room usable; traffic drops until rejoin", async () => {
  const host = await connect(ROOM_A, "host");
  const client = await connect(ROOM_A, "client");
  client.close();
  await closed(client);

  host.send(randomBytes(16)); // dropped: client gone

  const client2 = await connect(ROOM_A, "client");
  try {
    await assertSilent(client2);
    const msg = randomBytes(16);
    host.send(msg);
    const got = await nextMessage(client2);
    assert.ok(Buffer.from(got.data).equals(msg));
  } finally {
    closeAll(host, client2);
  }
});

test("rooms are isolated from each other", async () => {
  const hostA = await connect(ROOM_A, "host");
  const clientA = await connect(ROOM_A, "client");
  const hostB = await connect(ROOM_B, "host");
  const clientB = await connect(ROOM_B, "client");
  try {
    const msgA = randomBytes(16);
    hostA.send(msgA);
    const got = await nextMessage(clientA);
    assert.ok(Buffer.from(got.data).equals(msgA));
    await assertSilent(clientB);
    await assertSilent(hostB);
  } finally {
    closeAll(hostA, clientA, hostB, clientB);
  }
});

#!/usr/bin/env node
// Headless Pedals client for E2E tests (ARCHITECTURE.md "Testing").
//
// Usage:
//   node client.mjs --pair '<pedals://pair?...>' --expect <marker> [--timeout <s>] [--keep]
//
// --keep leaves the session running on the host (no `close` ctl) so a later
// client — e.g. the iOS simulator in scripts/e2e.sh — can attach and replay it.
//
// Speaks the full protocol as the iOS app would, using the reference crypto:
// connects to the relay as `client`, exchanges hellos, creates a session,
// attaches, runs `printf '<marker>-%s\n' ok` in the remote shell, and exits 0
// once `<marker>-ok` arrives decrypted on the stdout stream. Any protocol
// violation or timeout exits non-zero.

import { parseArgs } from "node:util";
import WebSocket from "ws";
import {
  deriveKeys,
  open,
  seal,
  encodeFrame,
  decodeFrame,
  encodeCtl,
  FrameType,
} from "./crypto-ref.mjs";

const { values: args } = parseArgs({
  options: {
    pair: { type: "string" },
    expect: { type: "string" },
    timeout: { type: "string", default: "30" },
    keep: { type: "boolean", default: false },
  },
});

if (!args.pair || !args.expect) {
  console.error(
    "usage: client.mjs --pair '<pedals://pair?...>' --expect <marker> [--timeout <s>]",
  );
  process.exit(2);
}

function fail(message) {
  console.error(`client.mjs: FAIL: ${message}`);
  process.exit(1);
}

// ---- pairing URL --------------------------------------------------------

const url = new URL(args.pair);
if (url.protocol !== "pedals:" || url.host !== "pair") fail(`not a pairing URL: ${args.pair}`);
const params = url.searchParams;
if (params.get("v") !== "1") fail(`unsupported version ${params.get("v")}`);
const relay = params.get("relay");
const room = params.get("room");
const secret = Buffer.from(params.get("s"), "base64url");
if (!relay || !/^[0-9a-f]{32}$/.test(room ?? "")) fail("malformed relay/room");
if (secret.length !== 32) fail(`secret must be 32 bytes, got ${secret.length}`);

const { h2c, c2h } = deriveKeys(secret);
const marker = args.expect;
const expected = `${marker}-ok`;

// ---- connection ---------------------------------------------------------

const roomURL = `${relay.replace(/\/$/, "")}/v1/room/${room}?role=client`;
console.error(`client.mjs: connecting to ${roomURL}`);
const ws = new WebSocket(roomURL);

const timer = setTimeout(() => {
  fail(`timed out after ${args.timeout}s (state: ${state})`);
}, Number(args.timeout) * 1000);

let sendSeq = 0;
let lastReceivedSeq = 0n;
let state = "connecting";
let sessionId = null;
let attached = false;
let stdoutText = "";

function sendFrame(frame) {
  ws.send(seal(c2h, ++sendSeq, frame));
}

function sendCtl(obj) {
  sendFrame(encodeCtl(obj));
}

ws.on("open", () => {
  // The host answers a client hello with its `sessions` list (whether it
  // joined before or after us) — that reply is the readiness signal we gate
  // `create` on, since relay traffic to an absent peer is dropped.
  state = "awaiting-host";
  sendCtl({
    t: "hello",
    who: "client",
    connEpoch: Math.floor(Math.random() * 0xffffffff),
    ver: 1,
  });
});

ws.on("error", (error) => fail(`websocket error: ${error.message}`));
ws.on("close", (code) => {
  if (state !== "done") fail(`websocket closed early (code ${code}, state ${state})`);
});

ws.on("message", (data, isBinary) => {
  if (!isBinary) return; // text frames are ignored per spec

  let plaintext, seq;
  try {
    ({ seq, plaintext } = open(h2c, Buffer.from(data)));
  } catch (error) {
    fail(`decryption failed: ${error.message}`);
  }
  if (seq <= lastReceivedSeq) return; // replay protection: drop
  lastReceivedSeq = seq;

  const frame = decodeFrame(plaintext);
  switch (frame.type) {
    case FrameType.ctl:
      handleCtl(JSON.parse(frame.payload.toString("utf8")));
      break;
    case FrameType.stdout:
    case FrameType.replay:
      if (frame.sessionId === sessionId) {
        stdoutText += frame.payload.toString("utf8");
        checkMarker();
      }
      break;
    default:
      fail(`unexpected frame type 0x${frame.type.toString(16)} from host`);
  }
});

function handleCtl(msg) {
  switch (msg.t) {
    case "hello":
      if (msg.who !== "host") fail(`unexpected hello from ${msg.who}`);
      console.error(`client.mjs: host hello (connEpoch ${msg.connEpoch})`);
      break;
    case "created":
      if (sessionId === null) {
        sessionId = msg.id;
        console.error(`client.mjs: session ${sessionId} created; attaching`);
        sendCtl({ t: "attach", id: sessionId });
        attached = true;
        // Run the marker command; the trailing newline executes it.
        sendFrame(
          encodeFrame(
            FrameType.stdin,
            sessionId,
            Buffer.from(`printf '${marker}-%s\\n' ok\n`, "utf8"),
          ),
        );
        state = "awaiting-marker";
      }
      break;
    case "sessions": {
      if (!Array.isArray(msg.list)) fail("sessions ctl missing list");
      console.error(
        `client.mjs: sessions: ${msg.list.map((s) => `#${s.id}(${s.alive ? "live" : "dead"})`).join(" ") || "none"}`,
      );
      if (state === "awaiting-host") {
        state = "awaiting-created";
        console.error("client.mjs: host is up; creating session");
        sendCtl({ t: "create", cwd: null, cols: 120, rows: 40 });
      }
      break;
    }
    case "title":
    case "exit":
      break;
    case "err":
      fail(`host err: ${msg.msg}`);
      break;
    default:
      fail(`unknown ctl message: ${JSON.stringify(msg)}`);
  }
}

function checkMarker() {
  if (state !== "awaiting-marker" || !attached) return;
  // The PTY echoes the typed command; require the marker on its own line so
  // only the printf *output* (not the echo of `printf '<marker>-%s\n' ok`)
  // counts.
  const lines = stdoutText.split(/\r?\n/);
  if (lines.some((line) => line.trim() === expected)) {
    state = "done";
    console.error(`client.mjs: OK — received "${expected}" decrypted end-to-end`);
    clearTimeout(timer);
    if (!args.keep) sendCtl({ t: "close", id: sessionId });
    ws.close();
    // Give the close ctl a beat to flush, then exit success.
    setTimeout(() => process.exit(0), 200).unref();
  }
}

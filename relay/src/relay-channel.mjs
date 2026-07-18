import { DurableObject } from "cloudflare:workers";
import { isId, writeComputerState } from "./core.mjs";

const HOST_TAG = "role:host";
const CLIENT_TAG = "role:client";
const CLOSE_REPLACED = 4000;
const CLOSE_BINDING_REVOKED = 4003;
const CLOSE_COMPUTER_REVOKED = 4004;
const OPEN = 1;
const HOST_NAME_MAX_LENGTH = 128;
const MAX_TEXT_BYTES = 512;
export const MAX_BINARY_BYTES = 1024 * 1024;
const MAX_BUFFERED_BYTES = 4 * 1024 * 1024;
export const CLIENT_SOURCE_ENVELOPE_VERSION = 0x02;
export const CLIENT_SOURCE_PRINCIPAL_BYTES = 32;
export const CLIENT_SOURCE_ENVELOPE_BYTES = 1 + CLIENT_SOURCE_PRINCIPAL_BYTES;
export const MAX_CLIENT_ACTIVE_CHANNELS = 16;
export const MAX_HOST_ACTIVE_CHANNELS = 256;

const textEncoder = new TextEncoder();

function validHostName(value) {
  return (
    typeof value === "string" &&
    value === value.trim() &&
    value.length > 0 &&
    value.length <= HOST_NAME_MAX_LENGTH &&
    !/[\u0000-\u001f\u007f]/.test(value)
  );
}

function attachmentOf(ws) {
  try {
    const value = ws.deserializeAttachment();
    if (!value || value.v !== 2 || !isId(value.computerId)) return null;
    if (typeof value.channel !== "string" || !isId(value.principalId)) return null;
    if (value.role === "client") return value;
    if (value.role === "host" && typeof value.active === "boolean") return value;
  } catch {
    // A socket without a valid serialized identity is never trusted.
  }
  return null;
}

function parseTrustedUpgrade(request) {
  if (
    request.method !== "GET" ||
    request.headers.get("upgrade")?.toLowerCase() !== "websocket"
  ) {
    return null;
  }
  const computerId = request.headers.get("x-pedals-computer-id");
  const channel = request.headers.get("x-pedals-channel");
  const role = request.headers.get("x-pedals-role");
  const principalId = request.headers.get("x-pedals-principal-id");
  if (
    !isId(computerId) ||
    !channel ||
    (role !== "host" && role !== "client") ||
    !isId(principalId)
  ) {
    return null;
  }
  return { computerId, channel, role, principalId };
}

function parseInternalAction(request) {
  if (request.method !== "POST") return null;
  const path = new URL(request.url).pathname;
  const computerId = request.headers.get("x-pedals-computer-id");
  if (!isId(computerId)) return null;
  if (path === "/internal/revoke-computer") {
    return { type: "computer", computerId };
  }
  const principalId = request.headers.get("x-pedals-principal-id");
  if (path === "/internal/revoke-client" && isId(principalId)) {
    return { type: "client", computerId, principalId };
  }
  return null;
}

function binaryView(message) {
  if (message instanceof ArrayBuffer) return new Uint8Array(message);
  if (ArrayBuffer.isView(message)) {
    return new Uint8Array(message.buffer, message.byteOffset, message.byteLength);
  }
  return null;
}

function authenticatedClientEnvelope(principalId, payload) {
  // principalId comes only from the serialized socket attachment populated
  // after the outer bearer has been authorized. Never parse a caller-supplied
  // prefix: a bound client must not be able to claim another client identity
  // inside the shared-secret E2EE hello.
  const principal = textEncoder.encode(principalId);
  if (principal.byteLength !== CLIENT_SOURCE_PRINCIPAL_BYTES) return null;
  const envelope = new Uint8Array(CLIENT_SOURCE_ENVELOPE_BYTES + payload.byteLength);
  envelope[0] = CLIENT_SOURCE_ENVELOPE_VERSION;
  envelope.set(principal, 1);
  envelope.set(payload, CLIENT_SOURCE_ENVELOPE_BYTES);
  return envelope;
}

export class RelayChannel extends DurableObject {
  retiredSockets = new WeakSet();
  stateWriteTail = Promise.resolve();

  constructor(ctx, env) {
    super(ctx, env);
    this.ctx = ctx;
    this.env = env;
  }

  async fetch(request) {
    const action = parseInternalAction(request);
    if (action) {
      return this.ctx.blockConcurrencyWhile(async () => this.applyRevocation(action));
    }

    const identity = parseTrustedUpgrade(request);
    if (!identity) return new Response("bad request", { status: 400 });

    // Recheck inside the same per-computer actor that processes revocations.
    // This closes the race where outer Worker auth succeeds just before a D1
    // binding/computer deletion, but the upgrade reaches the actor afterward.
    return this.ctx.blockConcurrencyWhile(async () => {
      if (!(await this.identityStillAuthorized(identity))) {
        return new Response("unauthorized", { status: 401 });
      }
      return this.acceptConnection(identity);
    });
  }

  async identityStillAuthorized(identity) {
    if (identity.role === "host") {
      const row = await this.env.DB
        .prepare(`SELECT 1 FROM computers WHERE id = ?1 AND revoked_at IS NULL`)
        .bind(identity.computerId)
        .first();
      return Boolean(row);
    }
    const row = await this.env.DB
      .prepare(
        `SELECT 1
           FROM client_computers b
           JOIN clients c ON c.id = b.client_id
           JOIN computers h ON h.id = b.computer_id
          WHERE b.client_id = ?1
            AND b.computer_id = ?2
            AND c.revoked_at IS NULL
            AND h.revoked_at IS NULL`,
      )
      .bind(identity.principalId, identity.computerId)
      .first();
    return Boolean(row);
  }

  acceptConnection(identity) {
    const channelLimit =
      identity.role === "client" ? MAX_CLIENT_ACTIVE_CHANNELS : MAX_HOST_ACTIVE_CHANNELS;
    const activeChannels = this.activeChannelsForPrincipal(identity);
    if (!activeChannels.has(identity.channel) && activeChannels.size >= channelLimit) {
      return new Response("active relay channel limit exceeded", {
        status: 429,
        headers: { "retry-after": "60" },
      });
    }

    const [client, server] = Object.values(new WebSocketPair());
    const baseAttachment = {
      v: 2,
      role: identity.role,
      computerId: identity.computerId,
      channel: identity.channel,
      principalId: identity.principalId,
    };

    if (identity.role === "host") {
      const previousHosts = this.socketsFor(HOST_TAG, identity.channel);
      const wasOnline = previousHosts.some((ws) => this.isActiveHostSlot(ws));

      this.ctx.acceptWebSocket(server, [HOST_TAG]);
      if (!this.safeSerialize(server, { ...baseAttachment, active: true })) {
        this.safeClose(server, 1011, "relay state unavailable");
        return new Response(null, { status: 101, webSocket: client });
      }

      for (const previous of previousHosts) {
        this.retiredSockets.add(previous);
        const state = attachmentOf(previous);
        if (state?.role === "host") {
          this.safeSerialize(previous, { ...state, active: false });
        }
      }
      for (const previous of previousHosts) {
        this.safeClose(previous, CLOSE_REPLACED, "replaced by new connection");
      }
      if (!wasOnline) this.notifyClients(identity.channel, true);
    } else {
      // One socket per logical client/channel bounds amplification while still
      // allowing the control channel and independent session channels.
      for (const previous of this.socketsFor(CLIENT_TAG, identity.channel)) {
        const state = attachmentOf(previous);
        if (state?.principalId === identity.principalId) {
          this.safeClose(previous, CLOSE_REPLACED, "replaced by new connection");
        }
      }
      this.ctx.acceptWebSocket(server, [CLIENT_TAG]);
      if (!this.safeSerialize(server, baseAttachment)) {
        this.safeClose(server, 1011, "relay state unavailable");
        return new Response(null, { status: 101, webSocket: client });
      }
      this.safeSend(server, this.presence(this.hasActiveHostSlot(identity.channel)));
    }

    return new Response(null, { status: 101, webSocket: client });
  }

  webSocketMessage(ws, message) {
    const state = attachmentOf(ws);
    if (!state) {
      this.retireSocket(ws, 1011, "invalid relay state");
      return;
    }

    if (typeof message === "string") {
      if (
        message.length > MAX_TEXT_BYTES ||
        new TextEncoder().encode(message).byteLength > MAX_TEXT_BYTES
      ) {
        this.retireSocket(ws, 1009, "relay metadata too large");
        return;
      }
      if (state.role === "host" && state.active && state.channel === "control") {
        this.handleHostState(ws, state, message);
      }
      return;
    }
    const binary = binaryView(message);
    if (!binary) {
      this.retireSocket(ws, 1003, "unsupported relay frame");
      return;
    }
    if (binary.byteLength > MAX_BINARY_BYTES) {
      this.retireSocket(ws, 1009, "relay frame too large");
      return;
    }

    if (state.role === "host") {
      if (!state.active) return;
      for (const client of this.socketsFor(CLIENT_TAG, state.channel)) {
        this.safeSend(client, message);
      }
      return;
    }

    const host = this.activeHostForSend(state.channel);
    if (host) {
      const envelope = authenticatedClientEnvelope(state.principalId, binary);
      if (!envelope) {
        this.retireSocket(ws, 1011, "invalid relay principal");
        return;
      }
      this.safeSend(host, envelope);
    }
  }

  webSocketClose(ws) {
    this.deactivateHost(ws);
  }

  webSocketError(ws) {
    this.deactivateHost(ws);
    this.safeClose(ws, 1011, "websocket error");
  }

  handleHostState(ws, state, message) {
    let value;
    try {
      value = JSON.parse(message);
    } catch {
      this.retireSocket(ws, 1008, "invalid host state");
      return;
    }
    if (
      !value ||
      Array.isArray(value) ||
      Object.keys(value).length !== 3 ||
      value.type !== "host-state" ||
      !Number.isSafeInteger(value.aliveTTYCount) ||
      value.aliveTTYCount < 0 ||
      value.aliveTTYCount > 10_000 ||
      !validHostName(value.hostName)
    ) {
      this.retireSocket(ws, 1008, "invalid host state");
      return;
    }

    this.enqueueStateWrite(state.computerId, {
      online: true,
      aliveTTYCount: value.aliveTTYCount,
      hostName: value.hostName,
      heartbeat: true,
    });
  }

  enqueueStateWrite(computerId, update) {
    const task = this.stateWriteTail.then(
      () => writeComputerState(this.env, computerId, update),
      () => writeComputerState(this.env, computerId, update),
    );
    this.stateWriteTail = task.catch(() => undefined);
    this.ctx.waitUntil(
      task.catch((error) => {
        console.error("host state write failed", error instanceof Error ? error.message : error);
      }),
    );
  }

  socketsFor(tag, channel) {
    return this.ctx
      .getWebSockets(tag)
      .filter((ws) => attachmentOf(ws)?.channel === channel);
  }

  activeChannelsForPrincipal(identity) {
    const tag = identity.role === "host" ? HOST_TAG : CLIENT_TAG;
    const channels = new Set();
    for (const ws of this.ctx.getWebSockets(tag)) {
      if (ws.readyState !== OPEN) continue;
      const state = attachmentOf(ws);
      if (
        state?.role === identity.role &&
        state.principalId === identity.principalId &&
        (state.role !== "host" || state.active)
      ) {
        channels.add(state.channel);
      }
    }
    return channels;
  }

  isActiveHostSlot(ws) {
    if (this.retiredSockets.has(ws)) return false;
    const state = attachmentOf(ws);
    return state?.role === "host" && state.active;
  }

  hasActiveHostSlot(channel, excluding = null) {
    return this.socketsFor(HOST_TAG, channel).some(
      (ws) => ws !== excluding && this.isActiveHostSlot(ws),
    );
  }

  activeHostForSend(channel) {
    return (
      this.socketsFor(HOST_TAG, channel).find(
        (ws) => ws.readyState === OPEN && this.isActiveHostSlot(ws),
      ) ?? null
    );
  }

  deactivateHost(ws) {
    if (this.retiredSockets.has(ws)) return false;
    const state = attachmentOf(ws);
    if (state?.role !== "host" || !state.active) return false;

    this.retiredSockets.add(ws);
    this.safeSerialize(ws, { ...state, active: false });
    if (!this.hasActiveHostSlot(state.channel, ws)) {
      this.notifyClients(state.channel, false);
      if (state.channel === "control") {
        this.enqueueStateWrite(state.computerId, { online: false });
      }
    }
    return true;
  }

  applyRevocation(action) {
    let closed = 0;
    for (const ws of [
      ...this.ctx.getWebSockets(HOST_TAG),
      ...this.ctx.getWebSockets(CLIENT_TAG),
    ]) {
      const state = attachmentOf(ws);
      if (!state || state.computerId !== action.computerId) continue;
      if (action.type === "client") {
        if (state.role !== "client" || state.principalId !== action.principalId) continue;
        this.safeClose(ws, CLOSE_BINDING_REVOKED, "binding revoked");
      } else {
        if (state.role === "host") {
          this.retiredSockets.add(ws);
          this.safeSerialize(ws, { ...state, active: false });
        }
        this.safeClose(ws, CLOSE_COMPUTER_REVOKED, "computer revoked");
      }
      closed += 1;
    }
    return new Response(null, {
      status: 204,
      headers: { "x-pedals-closed-sockets": String(closed) },
    });
  }

  retireSocket(ws, code, reason) {
    this.deactivateHost(ws);
    this.safeClose(ws, code, reason);
  }

  safeSend(ws, message) {
    if (ws.readyState !== OPEN) return false;
    if (Number(ws.bufferedAmount ?? 0) > MAX_BUFFERED_BYTES) {
      this.retireSocket(ws, 1013, "relay backpressure");
      return false;
    }
    try {
      ws.send(message);
      return true;
    } catch {
      this.retireSocket(ws, 1011, "relay send failed");
      return false;
    }
  }

  safeClose(ws, code, reason) {
    try {
      if (ws.readyState === OPEN) ws.close(code, reason);
    } catch {
      // The peer may already have disappeared.
    }
  }

  safeSerialize(ws, value) {
    try {
      ws.serializeAttachment(value);
      return true;
    } catch {
      return false;
    }
  }

  presence(online) {
    return JSON.stringify({ type: "presence", online });
  }

  notifyClients(channel, online) {
    const notice = this.presence(online);
    for (const client of this.socketsFor(CLIENT_TAG, channel)) {
      this.safeSend(client, notice);
    }
  }
}

import assert from "node:assert/strict";
import { Buffer } from "node:buffer";
import test from "node:test";

import {
  APNS_SURFACES,
  LIVE_ACTIVITY_ATTRIBUTES_TYPE,
  buildApnsPayload,
  classifyApnsResponse,
  createApnsClient,
  createProviderToken,
} from "../src/apns.mjs";

const keyPair = await crypto.subtle.generateKey(
  { name: "ECDSA", namedCurve: "P-256" },
  true,
  ["sign", "verify"],
);
const privateKey = await crypto.subtle.exportKey("pkcs8", keyPair.privateKey);
const keyBase64 = Buffer.from(privateKey).toString("base64");
const env = {
  APNS_PRIVATE_KEY_P8: `-----BEGIN PRIVATE KEY-----\n${keyBase64}\n-----END PRIVATE KEY-----`,
  APNS_KEY_ID: "KEY1234567",
  APNS_TEAM_ID: "TEAM123456",
};

function decodeJwtPart(value) {
  return JSON.parse(Buffer.from(value, "base64url").toString("utf8"));
}

test("uses only the air.build APNs topics", () => {
  assert.equal(
    APNS_SURFACES["ios-widget"].topic,
    "air.build.pedals.push-type.widgets",
  );
  assert.equal(
    APNS_SURFACES["watch-widget"].topic,
    "air.build.pedals.watchapp.push-type.widgets",
  );
  assert.equal(
    APNS_SURFACES["liveactivity-start"].topic,
    "air.build.pedals.push-type.liveactivity",
  );
  assert.equal(
    APNS_SURFACES["liveactivity-update"].topic,
    "air.build.pedals.push-type.liveactivity",
  );
});

test("creates and reuses a verifiable ES256 provider token", async () => {
  const now = 1_800_000_000_000;
  const first = await createProviderToken(env, { now });
  const parts = first.token.split(".");

  assert.equal(parts.length, 3);
  assert.deepEqual(decodeJwtPart(parts[0]), {
    alg: "ES256",
    kid: env.APNS_KEY_ID,
  });
  assert.deepEqual(decodeJwtPart(parts[1]), {
    iss: env.APNS_TEAM_ID,
    iat: Math.floor(now / 1000),
  });
  assert.equal(Buffer.from(parts[2], "base64url").length, 64);
  assert.equal(
    await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      keyPair.publicKey,
      Buffer.from(parts[2], "base64url"),
      new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
    ),
    true,
  );

  const reused = await createProviderToken(env, {
    now: now + 60_000,
    tokenCache: first.tokenCache,
  });
  assert.equal(reused.token, first.token);

  const rotated = await createProviderToken(env, {
    now: now + 50 * 60_000,
    tokenCache: first.tokenCache,
  });
  assert.notEqual(rotated.token, first.token);
});

test("builds only allow-listed widget and Live Activity payloads", () => {
  assert.deepEqual(buildApnsPayload("ios-widget", {}), {
    aps: { "content-changed": true },
  });
  assert.deepEqual(
    buildApnsPayload(
      "liveactivity-update",
      {
        state: {
          totalRunning: 3,
          sequence: 9,
          updatedAt: "2023-11-14T22:13:20Z",
          computers: [{ online: true }, { online: false }],
        },
        event: "update",
      },
      1_700_000_000_999,
    ),
    {
      aps: {
        timestamp: 1_700_000_000,
        event: "update",
        "stale-date": 1_700_000_300,
        "content-state": {
          totalRunning: 3,
          agentsRunning: 0,
          agentsWaiting: 0,
          onlineComputerCount: 1,
          offlineComputerCount: 1,
          updatedAt: 721_692_800,
          sequence: 9,
        },
      },
    },
  );
  // Agent counts flow into content-state when the aggregate carries them.
  assert.deepEqual(
    buildApnsPayload(
      "liveactivity-update",
      {
        state: {
          totalRunning: 0,
          agentsRunning: 2,
          agentsWaiting: 1,
          sequence: 12,
          updatedAt: "2023-11-14T22:13:20Z",
          computers: [{ online: true }],
        },
        event: "update",
      },
      1_700_000_000_999,
    ).aps["content-state"],
    {
      totalRunning: 0,
      agentsRunning: 2,
      agentsWaiting: 1,
      onlineComputerCount: 1,
      offlineComputerCount: 0,
      updatedAt: 721_692_800,
      sequence: 12,
    },
  );

  const start = buildApnsPayload(
    "liveactivity-start",
    {
      state: {
        totalRunning: 1,
        sequence: 10,
        updatedAt: "2001-01-01T00:00:00Z",
        computers: [{ online: true }],
      },
      event: "start",
    },
    1_800_000_000_000,
  );
  assert.equal(start.aps["attributes-type"], LIVE_ACTIVITY_ATTRIBUTES_TYPE);
  assert.equal(start.aps["input-push-token"], 1);
  assert.equal(start.aps["stale-date"], 978_307_500);
  assert.deepEqual(start.aps.attributes, { scope: "all" });
  assert.deepEqual(start.aps["content-state"], {
    totalRunning: 1,
    agentsRunning: 0,
    agentsWaiting: 0,
    onlineComputerCount: 1,
    offlineComputerCount: 0,
    updatedAt: 0,
    sequence: 10,
  });
  assert.equal(typeof start.aps.alert.body, "string");

  const ended = buildApnsPayload(
    "liveactivity-update",
    {
      state: {
        totalRunning: 0,
        sequence: 11,
        updatedAt: "2001-01-01T00:00:00Z",
        computers: [{ online: false }],
      },
      event: "end",
    },
    1_800_000_000_999,
  );
  assert.equal(ended.aps["dismissal-date"], 1_800_000_000);
  assert.equal(ended.aps["stale-date"], 978_307_500);
  assert.equal(ended.aps.event, "end");

  assert.throws(
    () => buildApnsPayload("ios-widget", { aps: { alert: "injected" } }),
    /not allowed/,
  );
  assert.throws(
    () =>
      buildApnsPayload("liveactivity-update", {
        state: {
          totalRunning: 1,
          sequence: 1,
          updatedAt: "2001-01-01T00:00:00Z",
          computers: [],
        },
        event: "start",
      }),
    /not valid/,
  );
  assert.throws(
    () => buildApnsPayload("unknown", {}),
    /not supported/,
  );
});

test("builds agent notification payloads with generic text and opaque sealed blob", () => {
  const sealed = Buffer.from("ciphertext").toString("base64");
  assert.deepEqual(
    buildApnsPayload("ios-notification", {
      category: "waiting",
      computerId: "c".repeat(32),
      sessionId: 7,
      hostName: "Studio",
      sealed,
    }),
    {
      aps: {
        alert: { title: "Studio", body: "An agent needs your input" },
        sound: "default",
        "thread-id": "c".repeat(32),
        category: "PEDALS_AGENT_NOTIFICATION",
        "mutable-content": 1,
      },
      pedals: {
        v: 1,
        computerId: "c".repeat(32),
        category: "waiting",
        sessionId: 7,
        sealed,
      },
    },
  );

  // Unmanaged agent: no session id; no host name falls back to "Pedals".
  const minimal = buildApnsPayload("ios-notification", {
    category: "done",
    computerId: "d".repeat(32),
  });
  assert.equal(minimal.aps.alert.title, "Pedals");
  assert.equal(minimal.aps.alert.body, "An agent finished its task");
  assert.equal(minimal.pedals.sessionId, undefined);
  assert.equal(minimal.pedals.sealed, undefined);

  assert.throws(
    () => buildApnsPayload("ios-notification", { category: "nope", computerId: "e".repeat(32) }),
    /category/,
  );
  assert.throws(
    () => buildApnsPayload("ios-notification", {
      category: "waiting",
      computerId: "e".repeat(32),
      sealed: "not base64!!",
    }),
    /base64/,
  );
  assert.throws(
    () => buildApnsPayload("ios-notification", {
      category: "waiting",
      computerId: "e".repeat(32),
      aps: { alert: "injected" },
    }),
    /not allowed/,
  );
});

test("sends sandbox widget pushes with fixed topic, type and body", async () => {
  let request = null;
  const client = createApnsClient(env, {
    now: () => 1_800_000_000_000,
    fetchImpl: async (url, init) => {
      request = { url, init };
      return new Response(null, {
        status: 200,
        headers: { "apns-id": "response-id" },
      });
    },
  });

  const result = await client.send(
    {
      token: "device/token",
      surface: "ios-widget",
      environment: "sandbox",
    },
    {},
  );

  assert.equal(request.url, "https://api.sandbox.push.apple.com/3/device/device%2Ftoken");
  assert.equal(request.init.method, "POST");
  assert.equal(request.init.headers["apns-push-type"], "widgets");
  assert.equal(request.init.headers["apns-topic"], APNS_SURFACES["ios-widget"].topic);
  assert.match(request.init.headers.authorization, /^bearer [^.]+\.[^.]+\.[^.]+$/);
  assert.deepEqual(JSON.parse(request.init.body), {
    aps: { "content-changed": true },
  });
  assert.deepEqual(
    { ok: result.ok, outcome: result.outcome, status: result.status, apnsId: result.apnsId },
    { ok: true, outcome: "success", status: 200, apnsId: "response-id" },
  );
  assert.equal(result.tokenCache.token, client.tokenCache.token);
});

test("retains Live Activity transitions while offline with event-specific expiry", async () => {
  const now = 1_800_000_000_000;
  const requests = [];
  const client = createApnsClient(env, {
    now: () => now,
    fetchImpl: async (url, init) => {
      requests.push({ url, init });
      return new Response(null, { status: 200 });
    },
  });
  const state = {
    totalRunning: 2,
    sequence: 12,
    updatedAt: new Date(now).toISOString(),
    computers: [{ online: true }],
  };

  await client.send(
    {
      token: "update-token",
      surface: "liveactivity-update",
      environment: "production",
    },
    { state, event: "update" },
  );
  await client.send(
    {
      token: "end-token",
      surface: "liveactivity-update",
      environment: "production",
    },
    { state: { ...state, totalRunning: 0, sequence: 13 }, event: "end" },
  );

  assert.equal(requests[0].init.headers["apns-expiration"], "1800000900");
  assert.equal(requests[0].init.headers["apns-priority"], "5");
  assert.equal(JSON.parse(requests[0].init.body).aps["stale-date"], 1_800_000_300);
  assert.equal(requests[1].init.headers["apns-expiration"], "1800014400");
  assert.equal(requests[1].init.headers["apns-priority"], "10");
  const endPayload = JSON.parse(requests[1].init.body);
  assert.equal(endPayload.aps["dismissal-date"], 1_800_000_000);
  assert.equal(endPayload.aps["stale-date"], 1_800_000_300);
});

test("classifies APNs responses for endpoint lifecycle and retry", () => {
  assert.equal(classifyApnsResponse(200), "success");
  assert.equal(classifyApnsResponse(400, "BadDeviceToken"), "invalidate");
  assert.equal(classifyApnsResponse(400, "DeviceTokenNotForTopic"), "invalidate");
  assert.equal(classifyApnsResponse(410, "Unregistered"), "invalidate");
  assert.equal(classifyApnsResponse(429, "TooManyRequests"), "retry");
  assert.equal(classifyApnsResponse(500, "InternalServerError"), "retry");
  assert.equal(classifyApnsResponse(503, "ServiceUnavailable"), "retry");
  assert.equal(classifyApnsResponse(400, "BadTopic"), "fatal");
  assert.equal(classifyApnsResponse(403, "InvalidProviderToken"), "fatal");
});

test("returns invalidation metadata and clears rejected provider tokens", async () => {
  const invalidDeviceClient = createApnsClient(env, {
    fetchImpl: async () =>
      new Response(JSON.stringify({ reason: "Unregistered", timestamp: 1234 }), {
        status: 410,
      }),
  });
  const invalidDevice = await invalidDeviceClient.send(
    { token: "dead", surface: "watch-widget", environment: "production" },
    {},
  );
  assert.equal(invalidDevice.outcome, "invalidate");
  assert.equal(invalidDevice.invalidatedAt, 1234);

  const invalidProviderClient = createApnsClient(env, {
    fetchImpl: async () =>
      new Response(JSON.stringify({ reason: "InvalidProviderToken" }), {
        status: 403,
      }),
  });
  const invalidProvider = await invalidProviderClient.send(
    { token: "device", surface: "ios-widget", environment: "production" },
    {},
  );
  assert.equal(invalidProvider.outcome, "fatal");
  assert.equal(invalidProvider.tokenCache, null);
  assert.equal(invalidProviderClient.tokenCache, null);

  const expiredProviderClient = createApnsClient(env, {
    fetchImpl: async () =>
      new Response(JSON.stringify({ reason: "ExpiredProviderToken" }), {
        status: 403,
      }),
  });
  const expiredProvider = await expiredProviderClient.send(
    { token: "device", surface: "ios-widget", environment: "production" },
    {},
  );
  assert.equal(expiredProvider.outcome, "retry");
  assert.equal(expiredProvider.tokenCache, null);
});

test("treats transport failures as retryable without exposing an endpoint URL", async () => {
  const client = createApnsClient(env, {
    fetchImpl: async () => {
      throw new Error("network down");
    },
  });
  const result = await client.send(
    { token: "secret-token", surface: "ios-widget", environment: "production" },
    {},
  );
  assert.deepEqual(
    { outcome: result.outcome, status: result.status, reason: result.reason },
    { outcome: "retry", status: 0, reason: "NetworkError" },
  );
  assert.equal("url" in result, false);
});

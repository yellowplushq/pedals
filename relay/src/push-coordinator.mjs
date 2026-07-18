import { DurableObject } from "cloudflare:workers";
import { createApnsClient } from "./apns.mjs";
import { aggregateClientState, isId } from "./core.mjs";

const PENDING_KEY = "pendingClientIds";
const FORCE_KEY = "forceClientIds";
const INFLIGHT_KEY = "inflightClientIds";
const INFLIGHT_FORCE_KEY = "inflightForceClientIds";
const TOKEN_CACHE_KEY = "apnsProviderToken";
const COALESCE_MILLISECONDS = 150;
const RETRY_MILLISECONDS = 15 * 60_000;
const FATAL_RETRY_MILLISECONDS = 24 * 60 * 60_000;
const MINIMUM_RETRY_MILLISECONDS = 60_000;
const MAXIMUM_RETRY_MILLISECONDS = 24 * 60 * 60_000;
const WATCHDOG_MILLISECONDS = 60_000;

function mergeIds(previous, incoming) {
  return [...new Set([...(previous ?? []), ...(incoming ?? [])])].filter(isId);
}

function fingerprint(state) {
  return JSON.stringify(state);
}

async function deliveryApnsId(endpointId, sequence, event) {
  const digest = new Uint8Array(
    await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(`${endpointId}:${sequence}:${event}`),
    ),
  ).slice(0, 16);
  digest[6] = (digest[6] & 0x0f) | 0x40;
  digest[8] = (digest[8] & 0x3f) | 0x80;
  const hex = [...digest].map((byte) => byte.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export function retryAtFromHeader(value, now = Date.now()) {
  if (typeof value !== "string" || value.trim() === "") {
    return now + RETRY_MILLISECONDS;
  }
  const trimmed = value.trim();
  let candidate;
  if (/^\d+$/.test(trimmed)) {
    candidate = now + Number(trimmed) * 1000;
  } else {
    candidate = Date.parse(trimmed);
  }
  if (!Number.isFinite(candidate) || candidate <= now) {
    return now + RETRY_MILLISECONDS;
  }
  return Math.min(
    now + MAXIMUM_RETRY_MILLISECONDS,
    Math.max(now + MINIMUM_RETRY_MILLISECONDS, candidate),
  );
}

function earlier(first, second) {
  if (!Number.isFinite(first)) return second;
  if (!Number.isFinite(second)) return first;
  return Math.min(first, second);
}

export class PushCoordinator extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.ctx = ctx;
    this.env = env;
  }

  async fetch(request) {
    if (request.method !== "POST" || new URL(request.url).pathname !== "/invalidate") {
      return new Response("not found", { status: 404 });
    }

    let body;
    try {
      body = await request.json();
    } catch {
      return new Response("bad request", { status: 400 });
    }
    if (!Array.isArray(body.clientIds) || body.clientIds.some((id) => !isId(id))) {
      return new Response("bad request", { status: 400 });
    }

    await this.ctx.blockConcurrencyWhile(async () => {
      const pending = await this.ctx.storage.get(PENDING_KEY);
      await this.ctx.storage.put(PENDING_KEY, mergeIds(pending, body.clientIds));
      if (body.force === true) {
        const forced = await this.ctx.storage.get(FORCE_KEY);
        await this.ctx.storage.put(FORCE_KEY, mergeIds(forced, body.clientIds));
      }
      const alarm = await this.ctx.storage.getAlarm();
      const desired = Date.now() + COALESCE_MILLISECONDS;
      if (alarm === null || alarm > desired) await this.ctx.storage.setAlarm(desired);
    });
    return new Response(null, { status: 202 });
  }

  async alarm() {
    const { pending, forced } = await this.ctx.blockConcurrencyWhile(async () => {
      const [pendingClientIds, forcedClientIds, inflightClientIds, inflightForcedIds] =
        await Promise.all([
        this.ctx.storage.get(PENDING_KEY),
        this.ctx.storage.get(FORCE_KEY),
        this.ctx.storage.get(INFLIGHT_KEY),
        this.ctx.storage.get(INFLIGHT_FORCE_KEY),
      ]);
      const work = mergeIds(inflightClientIds, pendingClientIds);
      const workForced = mergeIds(inflightForcedIds, forcedClientIds);
      if (work.length === 0) {
        await this.ctx.storage.delete([
          PENDING_KEY,
          FORCE_KEY,
          INFLIGHT_KEY,
          INFLIGHT_FORCE_KEY,
        ]);
        await this.ctx.storage.deleteAlarm();
        return { pending: [], forced: [] };
      }
      await this.ctx.storage.put(INFLIGHT_KEY, work);
      if (workForced.length > 0) {
        await this.ctx.storage.put(INFLIGHT_FORCE_KEY, workForced);
      }
      await this.ctx.storage.delete([PENDING_KEY, FORCE_KEY]);
      // If the invocation is terminated after taking work, this durable alarm
      // makes the in-flight set visible to a later retry.
      await this.ctx.storage.setAlarm(Date.now() + WATCHDOG_MILLISECONDS);
      return { pending: work, forced: workForced };
    });
    const forcedSet = new Set(forced ?? []);
    const retries = [];
    const forcedRetries = [];
    let earliestRetryAt = null;

    for (const clientId of pending ?? []) {
      try {
        const retryAt = await this.deliverClient(clientId, forcedSet.has(clientId));
        if (Number.isFinite(retryAt)) {
          retries.push(clientId);
          if (forcedSet.has(clientId)) forcedRetries.push(clientId);
          earliestRetryAt = earlier(earliestRetryAt, retryAt);
        }
      } catch (error) {
        const retryAt = Date.now() + RETRY_MILLISECONDS;
        await this.deferClient(clientId, retryAt);
        retries.push(clientId);
        if (forcedSet.has(clientId)) forcedRetries.push(clientId);
        earliestRetryAt = earlier(earliestRetryAt, retryAt);
        console.error("APNs delivery failed", error instanceof Error ? error.message : error);
      }
    }

    await this.ctx.blockConcurrencyWhile(async () => {
      const [currentPending, currentForced] = await Promise.all([
        this.ctx.storage.get(PENDING_KEY),
        this.ctx.storage.get(FORCE_KEY),
      ]);
      const nextPending = mergeIds(currentPending, retries);
      const nextForced = mergeIds(currentForced, forcedRetries);
      await this.ctx.storage.delete([INFLIGHT_KEY, INFLIGHT_FORCE_KEY]);
      if (nextPending.length === 0) {
        await this.ctx.storage.delete([PENDING_KEY, FORCE_KEY]);
        await this.ctx.storage.deleteAlarm();
        return;
      }
      await this.ctx.storage.put(PENDING_KEY, nextPending);
      if (nextForced.length > 0) {
        await this.ctx.storage.put(FORCE_KEY, nextForced);
      } else {
        await this.ctx.storage.delete(FORCE_KEY);
      }
      // `setAlarm` replaces the 60-second crash watchdog installed above.
      // Fresh invalidations that arrived during delivery run immediately;
      // otherwise APNs Retry-After / durable endpoint backoff wins.
      const hasFreshWork = (currentPending ?? []).length > 0;
      const desired = hasFreshWork
        ? Date.now() + COALESCE_MILLISECONDS
        : Math.max(Date.now() + COALESCE_MILLISECONDS, earliestRetryAt ?? Date.now() + RETRY_MILLISECONDS);
      await this.ctx.storage.setAlarm(desired);
    });
  }

  async deliverClient(clientId, force) {
    const state = await aggregateClientState(this.env.DB, clientId);
    const result = await this.env.DB
      .prepare(
        `SELECT id, surface, apns_environment AS environment, token,
                activity_key AS activityId, last_sequence AS lastSequence,
                last_total_running AS lastTotalRunning,
                retry_not_before AS retryNotBefore
           FROM push_endpoints
          WHERE client_id = ?1 AND invalidated_at IS NULL
          ORDER BY id`,
      )
      .bind(clientId)
      .all();
    const endpoints = result.results;
    if (endpoints.length === 0) {
      await this.clearClientDeferral(clientId);
      return null;
    }

    const cached = await this.ctx.storage.get(TOKEN_CACHE_KEY);
    const apns = createApnsClient(this.env, { tokenCache: cached ?? null });
    let earliestRetryAt = null;
    let pushed = false;
    const now = Date.now();

    for (const endpoint of endpoints) {
      if (!force && Number(endpoint.lastSequence) >= state.sequence) continue;
      const retryNotBefore = Number(endpoint.retryNotBefore);
      if (Number.isFinite(retryNotBefore) && retryNotBefore > Math.floor(now / 1000)) {
        earliestRetryAt = earlier(earliestRetryAt, retryNotBefore * 1000);
        continue;
      }
      const surface = endpoint.surface;
      let payload = {};

      if (surface === "liveactivity-start") {
        if (state.totalRunning === 0 || Number(endpoint.lastTotalRunning ?? 0) > 0) {
          await this.markDelivered(endpoint.id, state);
          continue;
        }
        payload = { state, event: "start" };
      } else if (surface === "liveactivity-update") {
        payload = {
          state,
          event: state.totalRunning === 0 ? "end" : "update",
        };
      }

      const request = {
        token: endpoint.token,
        surface,
        environment: endpoint.environment,
        apnsId: await deliveryApnsId(
          endpoint.id,
          state.sequence,
          payload.event ?? surface,
        ),
      };
      let outcome;
      try {
        outcome = await apns.send(request, payload);
        if (outcome.reason === "ExpiredProviderToken") {
          // The client cleared its provider-token cache; one immediate resend
          // avoids delaying a valid state transition for the normal backoff.
          outcome = await apns.send(request, payload);
        }
      } catch (error) {
        const retryAt = now + RETRY_MILLISECONDS;
        await this.deferEndpoint(
          endpoint.id,
          retryAt,
          error instanceof Error ? error.message : "ProviderConfigurationError",
        );
        earliestRetryAt = earlier(earliestRetryAt, retryAt);
        continue;
      }
      if (outcome.tokenCache) {
        await this.ctx.storage.put(TOKEN_CACHE_KEY, outcome.tokenCache);
      } else {
        await this.ctx.storage.delete(TOKEN_CACHE_KEY);
      }

      if (outcome.outcome === "success") {
        const endActivity = surface === "liveactivity-update" && state.totalRunning === 0;
        if (endActivity) {
          await this.deleteEndpoint(endpoint.id);
        } else {
          await this.markDelivered(endpoint.id, state);
        }
        pushed = true;
      } else if (outcome.outcome === "invalidate") {
        if (surface === "liveactivity-update") {
          await this.deleteEndpoint(endpoint.id);
        } else {
          await this.invalidateEndpoint(endpoint.id);
        }
      } else if (outcome.outcome === "retry") {
        const retryAt = retryAtFromHeader(outcome.retryAfter, now);
        await this.deferEndpoint(endpoint.id, retryAt, outcome.reason ?? "RetryableAPNsError");
        earliestRetryAt = earlier(earliestRetryAt, retryAt);
      } else {
        // Payload/topic/configuration failures cannot succeed on a minute loop.
        // Keep the registration recoverable, but quarantine it for a day; a
        // fresh PUT clears the deferral immediately.
        const retryAt = now + FATAL_RETRY_MILLISECONDS;
        await this.deferEndpoint(endpoint.id, retryAt, outcome.reason ?? "FatalAPNsError");
        earliestRetryAt = earlier(earliestRetryAt, retryAt);
      }
    }

    if (pushed) {
      await this.env.DB
        .prepare(
          `UPDATE client_delivery_state
              SET last_fingerprint = ?2, last_pushed_at = ?3
            WHERE client_id = ?1`,
        )
        .bind(clientId, fingerprint(state), Math.floor(Date.now() / 1000))
        .run();
    }
    await this.clearClientDeferral(clientId);
    return earliestRetryAt;
  }

  async markDelivered(endpointId, state) {
    const now = Math.floor(Date.now() / 1000);
    await this.env.DB
      .prepare(
          `UPDATE push_endpoints
            SET last_sequence = ?2,
                last_total_running = ?3,
                updated_at = ?4,
                retry_not_before = NULL,
                failure_count = 0,
                last_failure_reason = NULL
          WHERE id = ?1`,
      )
      .bind(endpointId, state.sequence, state.totalRunning, now)
      .run();
  }

  async deleteEndpoint(endpointId) {
    await this.env.DB
      .prepare(`DELETE FROM push_endpoints WHERE id = ?1`)
      .bind(endpointId)
      .run();
  }

  async invalidateEndpoint(endpointId) {
    await this.env.DB
      .prepare(`UPDATE push_endpoints SET invalidated_at = ?2 WHERE id = ?1`)
      .bind(endpointId, Math.floor(Date.now() / 1000))
      .run();
  }

  async deferEndpoint(endpointId, retryAtMilliseconds, reason) {
    const retryAt = Math.floor(retryAtMilliseconds / 1000);
    await this.env.DB
      .prepare(
        `UPDATE push_endpoints
            SET retry_not_before = ?2,
                failure_count = failure_count + 1,
                last_failure_reason = ?3,
                updated_at = ?4
          WHERE id = ?1`,
      )
      .bind(
        endpointId,
        retryAt,
        String(reason ?? "APNsError").slice(0, 128),
        Math.floor(Date.now() / 1000),
      )
      .run();
  }

  async deferClient(clientId, retryAtMilliseconds) {
    await this.env.DB
      .prepare(
        `UPDATE client_delivery_state
            SET retry_not_before = ?2
          WHERE client_id = ?1`,
      )
      .bind(clientId, Math.floor(retryAtMilliseconds / 1000))
      .run();
  }

  async clearClientDeferral(clientId) {
    await this.env.DB
      .prepare(
        `UPDATE client_delivery_state
            SET retry_not_before = NULL
          WHERE client_id = ?1 AND retry_not_before IS NOT NULL`,
      )
      .bind(clientId)
      .run();
  }
}

PRAGMA foreign_keys = ON;

-- GC lookup paths for the bounded personal deployment. The predicates mirror
-- the scheduled cleanup and avoid full-table scans as the service approaches
-- its global capacity limits.
CREATE INDEX clients_orphan_gc
  ON clients (created_at, id)
  WHERE revoked_at IS NULL;

CREATE INDEX computers_orphan_gc
  ON computers (created_at, id)
  WHERE revoked_at IS NULL;

CREATE INDEX pairing_invites_global_expiry
  ON pairing_invites (expires_at, consumed_at);

-- APNs endpoints are delayed after retryable or configuration failures. A new
-- registration clears these fields and proves the client still wants delivery.
ALTER TABLE push_endpoints ADD COLUMN retry_not_before INTEGER;
ALTER TABLE push_endpoints ADD COLUMN failure_count INTEGER NOT NULL DEFAULT 0
  CHECK (failure_count >= 0);
ALTER TABLE push_endpoints ADD COLUMN last_failure_reason TEXT
  CHECK (last_failure_reason IS NULL OR length(last_failure_reason) <= 128);

ALTER TABLE client_delivery_state ADD COLUMN retry_not_before INTEGER;

CREATE INDEX push_endpoints_reconcile
  ON push_endpoints (retry_not_before, client_id)
  WHERE invalidated_at IS NULL;

-- A tiny persistent cursor makes the minute reconciliation sweep round-robin
-- instead of permanently favoring the first 25 client IDs.
CREATE TABLE service_runtime_state (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at INTEGER NOT NULL
) STRICT, WITHOUT ROWID;

-- Computer reset commits this outbox row in the same D1 transaction that
-- deletes the computer. Cron retries the Durable Object socket revocation until
-- it is acknowledged, so a transient internal error cannot strand live access.
CREATE TABLE relay_revocation_outbox (
  id TEXT PRIMARY KEY CHECK (length(id) = 32),
  kind TEXT NOT NULL CHECK (kind = 'computer'),
  computer_id TEXT NOT NULL CHECK (length(computer_id) = 32),
  principal_id TEXT NOT NULL DEFAULT '' CHECK (principal_id = ''),
  created_at INTEGER NOT NULL,
  attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  next_attempt_at INTEGER NOT NULL DEFAULT 0,
  last_error TEXT CHECK (last_error IS NULL OR length(last_error) <= 256),
  UNIQUE (kind, computer_id, principal_id)
) STRICT;

CREATE INDEX relay_revocation_due
  ON relay_revocation_outbox (next_attempt_at, created_at);

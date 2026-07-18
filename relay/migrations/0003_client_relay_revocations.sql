PRAGMA foreign_keys = ON;

-- Binding deletion needs the same durable socket-revocation guarantee as a
-- whole-computer reset. Rebuild the outbox so a row can target either every
-- socket for a computer or one authenticated client principal.
CREATE TABLE relay_revocation_outbox_v2 (
  id TEXT PRIMARY KEY CHECK (length(id) = 32),
  kind TEXT NOT NULL CHECK (kind IN ('computer', 'client')),
  computer_id TEXT NOT NULL CHECK (length(computer_id) = 32),
  principal_id TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL,
  attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  next_attempt_at INTEGER NOT NULL DEFAULT 0,
  last_error TEXT CHECK (last_error IS NULL OR length(last_error) <= 256),
  CHECK (
    (kind = 'computer' AND principal_id = '')
    OR
    (kind = 'client'
      AND length(principal_id) = 32
      AND principal_id NOT GLOB '*[^0-9a-f]*')
  ),
  UNIQUE (kind, computer_id, principal_id)
) STRICT;

INSERT INTO relay_revocation_outbox_v2
  (id, kind, computer_id, principal_id, created_at, attempt_count,
   next_attempt_at, last_error)
SELECT id, kind, computer_id, principal_id, created_at, attempt_count,
       next_attempt_at, last_error
  FROM relay_revocation_outbox;

DROP TABLE relay_revocation_outbox;
ALTER TABLE relay_revocation_outbox_v2 RENAME TO relay_revocation_outbox;

CREATE INDEX relay_revocation_due
  ON relay_revocation_outbox (next_attempt_at, created_at);

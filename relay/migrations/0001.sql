PRAGMA foreign_keys = ON;

CREATE TABLE computers (
  id TEXT PRIMARY KEY CHECK (length(id) = 32),
  host_token_hash TEXT NOT NULL UNIQUE CHECK (length(host_token_hash) = 64),
  created_at INTEGER NOT NULL,
  revoked_at INTEGER
) STRICT;

CREATE TABLE computer_state (
  computer_id TEXT PRIMARY KEY REFERENCES computers(id) ON DELETE CASCADE,
  revision INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0),
  mutation_id TEXT CHECK (mutation_id IS NULL OR length(mutation_id) = 32),
  host_name TEXT CHECK (host_name IS NULL OR (length(host_name) BETWEEN 1 AND 128)),
  alive_tty_count INTEGER NOT NULL DEFAULT 0 CHECK (alive_tty_count BETWEEN 0 AND 10000),
  online INTEGER NOT NULL DEFAULT 0 CHECK (online IN (0, 1)),
  last_seen_at INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT 0
) STRICT;

CREATE INDEX computer_state_stale ON computer_state (online, last_seen_at);

CREATE TABLE computer_reset_tombstones (
  computer_id TEXT PRIMARY KEY CHECK (length(computer_id) = 32),
  host_token_hash TEXT NOT NULL UNIQUE CHECK (length(host_token_hash) = 64),
  deleted_at INTEGER NOT NULL
) STRICT;

CREATE INDEX computer_reset_tombstones_expiry
  ON computer_reset_tombstones (deleted_at);

CREATE TABLE clients (
  id TEXT PRIMARY KEY CHECK (length(id) = 32),
  auth_token_hash TEXT NOT NULL UNIQUE CHECK (length(auth_token_hash) = 64),
  status_token_hash TEXT NOT NULL UNIQUE CHECK (length(status_token_hash) = 64),
  created_at INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL,
  revoked_at INTEGER
) STRICT;

CREATE TABLE client_computers (
  client_id TEXT NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
  computer_id TEXT NOT NULL REFERENCES computers(id) ON DELETE CASCADE,
  mutation_id TEXT NOT NULL CHECK (length(mutation_id) = 32),
  created_at INTEGER NOT NULL,
  PRIMARY KEY (client_id, computer_id)
) STRICT, WITHOUT ROWID;

CREATE INDEX client_computers_by_computer
  ON client_computers (computer_id, client_id);

CREATE TABLE pairing_invites (
  token_hash TEXT PRIMARY KEY CHECK (length(token_hash) = 64),
  computer_id TEXT NOT NULL REFERENCES computers(id) ON DELETE CASCADE,
  expires_at INTEGER NOT NULL,
  consumed_at INTEGER,
  consumed_by TEXT REFERENCES clients(id) ON DELETE SET NULL,
  consume_nonce TEXT,
  created_at INTEGER NOT NULL
) STRICT;

CREATE INDEX pairing_invites_by_computer
  ON pairing_invites (computer_id, expires_at);

CREATE TABLE push_endpoints (
  id TEXT PRIMARY KEY CHECK (length(id) = 32),
  client_id TEXT NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
  surface TEXT NOT NULL CHECK (
    surface IN ('ios-widget', 'watch-widget', 'liveactivity-start', 'liveactivity-update')
  ),
  apns_environment TEXT NOT NULL CHECK (apns_environment IN ('sandbox', 'production')),
  token TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE CHECK (length(token_hash) = 64),
  activity_key TEXT NOT NULL DEFAULT '' CHECK (
    surface = 'liveactivity-update' OR activity_key = ''
  ),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  invalidated_at INTEGER,
  last_sequence INTEGER NOT NULL DEFAULT -1 CHECK (last_sequence >= -1),
  last_total_running INTEGER,
  UNIQUE (client_id, surface, activity_key)
) STRICT;

CREATE INDEX push_endpoints_by_client
  ON push_endpoints (client_id, invalidated_at);

CREATE TRIGGER push_endpoints_limit
BEFORE INSERT ON push_endpoints
WHEN NOT EXISTS (
       SELECT 1 FROM push_endpoints
        WHERE client_id = NEW.client_id
          AND surface = NEW.surface
          AND activity_key = NEW.activity_key
     )
 AND (
       SELECT COUNT(*) FROM push_endpoints
        WHERE client_id = NEW.client_id
          AND invalidated_at IS NULL
     ) >= 8
BEGIN
  SELECT RAISE(ABORT, 'push endpoint limit exceeded');
END;

CREATE TABLE client_delivery_state (
  client_id TEXT PRIMARY KEY REFERENCES clients(id) ON DELETE CASCADE,
  sequence INTEGER NOT NULL DEFAULT 0 CHECK (sequence >= 0),
  last_fingerprint TEXT,
  last_pushed_at INTEGER
) STRICT;

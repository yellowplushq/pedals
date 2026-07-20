PRAGMA foreign_keys = ON;

-- Protocol refactor: the per-computer Durable Object owns the live terminal
-- directory and projects only its derived online/count state into D1. Old
-- heartbeat leases are deliberately discarded; every current desktop must
-- publish a fresh DO snapshot after deployment.
CREATE TABLE computer_state_v3 (
  computer_id TEXT PRIMARY KEY REFERENCES computers(id) ON DELETE CASCADE,
  revision INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0),
  mutation_id TEXT CHECK (mutation_id IS NULL OR length(mutation_id) = 32),
  host_name TEXT CHECK (host_name IS NULL OR (length(host_name) BETWEEN 1 AND 128)),
  running_terminal_count INTEGER NOT NULL DEFAULT 0
    CHECK (running_terminal_count BETWEEN 0 AND 255),
  online INTEGER NOT NULL DEFAULT 0 CHECK (online IN (0, 1)),
  updated_at INTEGER NOT NULL DEFAULT 0
) STRICT;

INSERT INTO computer_state_v3
  (computer_id, revision, mutation_id, host_name, running_terminal_count, online, updated_at)
SELECT computer_id, revision, mutation_id, host_name, 0, 0, updated_at
  FROM computer_state;

DROP TABLE computer_state;
ALTER TABLE computer_state_v3 RENAME TO computer_state;

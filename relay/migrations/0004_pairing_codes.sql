PRAGMA foreign_keys = ON;

-- The code flow replaces the unreachable QR/invitation API completely.
DROP TABLE IF EXISTS pairing_invites;

-- An 8-digit code is only a short-lived rendezvous handle. The Worker stores
-- public Curve25519 keys and the host-encrypted E2EE secret, never the secret
-- itself. Sessions are single-claim and disappear after 15 minutes.
CREATE TABLE pairing_sessions (
  id TEXT PRIMARY KEY CHECK (length(id) = 32),
  code_hash TEXT NOT NULL UNIQUE CHECK (length(code_hash) = 64),
  computer_id TEXT NOT NULL REFERENCES computers(id) ON DELETE CASCADE,
  host_public_key TEXT NOT NULL CHECK (length(host_public_key) = 43),
  client_public_key TEXT CHECK (
    client_public_key IS NULL OR length(client_public_key) = 43
  ),
  claimed_by TEXT REFERENCES clients(id) ON DELETE CASCADE,
  encrypted_secret TEXT CHECK (
    encrypted_secret IS NULL OR length(encrypted_secret) BETWEEN 64 AND 256
  ),
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  completed_at INTEGER,
  CHECK (
    (claimed_by IS NULL AND client_public_key IS NULL)
    OR
    (claimed_by IS NOT NULL AND client_public_key IS NOT NULL)
  ),
  CHECK (encrypted_secret IS NULL OR completed_at IS NOT NULL)
) STRICT;

CREATE INDEX pairing_sessions_by_computer
  ON pairing_sessions (computer_id, expires_at);

CREATE INDEX pairing_sessions_expiry
  ON pairing_sessions (expires_at);

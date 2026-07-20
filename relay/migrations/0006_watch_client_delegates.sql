PRAGMA foreign_keys = ON;

-- A paired Watch needs its own relay principal so its sockets never replace
-- the iPhone's sockets. The parent edge lets an iPhone unbind revoke both
-- principals atomically without storing any E2EE material in D1.
CREATE TABLE client_delegates (
  parent_client_id TEXT NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
  delegate_client_id TEXT PRIMARY KEY REFERENCES clients(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind = 'watch-terminal'),
  created_at INTEGER NOT NULL,
  CHECK (parent_client_id != delegate_client_id),
  UNIQUE (parent_client_id, kind)
) STRICT;

CREATE INDEX client_delegates_by_parent
  ON client_delegates (parent_client_id, delegate_client_id);

# Migrations (policy — machinery lands with M2)

All persisted structures carry versions (format, record schema, attachment, manifest, KDF config). A migration always runs as: backup → validate → migrate in a separate transaction → validate every record → atomic commit → keep rollback state until success. Security is never silently downgraded (e.g. KDF parameters may only ratchet up). Readers below `minimum reader version` fail safely with a clear message; unknown mandatory fields/flags are rejected, never skipped.

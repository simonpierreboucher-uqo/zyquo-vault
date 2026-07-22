# Contributing to Zyquo Vault

- Read `CLAUDE.md` first — it is the normative specification; `docs/` explains the implementation.
- Everything must build and test from the terminal: `./scripts/build.sh && ./scripts/test.sh`. No Xcode project files will be accepted.
- All CI gates must pass: `audit-forbidden-apis.sh`, `audit-design-tokens.sh`, `audit-dependencies.sh`, `lint.sh ci`.
- Security-relevant changes need an ADR in `docs/decisions/` and updates to `docs/cryptography.md` / `docs/vault-format.md` when bytes change.
- Never commit real credentials, even in fixtures — use `example-…-not-real` markers.
- Suspected vulnerabilities: see `SECURITY.md`, not the issue tracker.

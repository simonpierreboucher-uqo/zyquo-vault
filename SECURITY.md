# Security policy

## Supported versions

Zyquo Vault is pre-release (milestones M0–M1). There is no supported production version yet, and the on-disk format may still change before v1.0.

## Reporting a vulnerability

Email **spbou4@icloud.com** with:

- a description of the issue and the component affected (crypto, storage, UI, CLI),
- reproduction steps or a proof of concept,
- the commit hash or version you tested,
- your assessment of impact (confidentiality / integrity / availability).

Please **do not disclose publicly** (issues, social media) before we have coordinated a fix. We will acknowledge reports as quickly as we can and keep you informed of progress; we do not promise fixed response times and prefer honesty over unsupported SLAs.

## Scope notes for researchers

- The cryptographic design is documented in `docs/cryptography.md` and the format in `docs/vault-format.md`; both are written to be independently implementable — divergence between docs and code is itself a reportable bug.
- The threat model (`docs/threat-model.md`) lists explicit non-goals (e.g. malware with process-memory access on an unlocked session). Reports inside documented non-goals are still welcome if they show the boundary is drawn wrong.
- Fixtures and test vectors use obviously fake secrets (`example-password-not-real`); anything resembling a real credential in the repo is a bug.

## Audit status

**Not yet independently audited.** Until a professional audit of the storage format and cryptographic implementation is complete, Zyquo Vault should not be the sole storage location for irreplaceable production credentials.

## Dependency policy

External dependencies are minimal and reviewed (license, maintenance, security posture) before adoption. The only vendored third-party code is the official Argon2 reference implementation (see `docs/decisions/ADR-0002-argon2-vendored-reference.md`, pinned by commit). `scripts/audit-dependencies.sh` and `scripts/audit-forbidden-apis.sh` gate CI.

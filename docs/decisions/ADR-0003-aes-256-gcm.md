# ADR-0003 — AES-256-GCM as the single canonical AEAD for format v1

**Status:** accepted (2026-07-22)

## Context

§5.5 requires one canonical AEAD: AES-256-GCM or ChaCha20-Poly1305, both via CryptoKit.

## Decision

**AES-256-GCM.** Rationale: hardware acceleration on every supported Mac (Apple Silicon AES instructions), CryptoKit's implementation is constant-time and audited by Apple, and GCM's 12-byte-nonce/16-byte-tag layout matches the fixed wire format. ChaCha20-Poly1305 would be the choice for platforms without AES hardware, which is not our case.

## Consequences

- Algorithm id 1 in headers/AAD is AES-256-GCM; the enum leaves room for ChaCha20-Poly1305 as id 2 if a future format version wants it.
- Nonces are 96-bit random per message; with per-record/per-attachment DEKs the messages-per-key count stays far below birthday-bound concerns for random nonces.

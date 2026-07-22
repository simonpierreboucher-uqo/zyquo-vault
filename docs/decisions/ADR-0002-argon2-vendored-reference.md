# ADR-0002 — Vendor the official Argon2 reference implementation

**Status:** accepted (2026-07-22)

## Context

§5.3 requires Argon2id via maintained Swift bindings to the official reference, or — if nothing qualifies — vendoring the official C reference. Survey result: the Swift wrappers on offer (e.g. community `Argon2Swift`-style packages) are thin, sparsely maintained, and several bundle outdated copies of the C code or add transitive dependencies; none is an "official binding". CryptoKit offers no Argon2.

## Decision

Vendor the official PHC-winner reference (github.com/P-H-C/phc-winner-argon2, commit `f57e61e19229e23c4445b85494dbf7c07de721cb`, CC0/Apache-2.0 dual license) as the `CArgon2` SwiftPM C target: `argon2.c core.c encoding.c ref.c thread.c blake2b.c` + headers, unmodified. The portable `ref.c` backend is used (no SSE; correct on Apple Silicon). A minimal Swift wrapper (`Argon2id.swift`) validates parameters against floors/ceilings before allocation, returns typed errors, never logs inputs, and zeroizes partial output on failure.

## Verification

The 8 official Argon2id known-answer vectors from the reference `test.c` run against the vendored code in CI.

## Consequences

- No external package risk; the version is pinned by construction. Updates are a manual, reviewed re-vendor.
- We maintain ~10 C files; the audit surface is the upstream reference itself, which is what auditors want to see anyway.

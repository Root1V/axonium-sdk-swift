# Axonium for Swift

The Axonium SDK for the Prometheus inference platform, for macOS, iOS, iPadOS, visionOS and
watchOS.

> **Status: M0.** The contract layer is here and is held to the shared corpus by tests. The HTTP
> client is not. See [CHANGELOG.md](CHANGELOG.md) for what exists today and
> [ROADMAP.md](ROADMAP.md) for the order the rest arrives in.

```swift
.package(url: "https://github.com/Root1V/axonium-sdk-swift", from: "0.1.0")
```

## Why this is a separate repository

The other three SDKs live together in [`Root1V/axonium-sdk`](https://github.com/Root1V/axonium-sdk),
under `python/`, `go/` and `rust/`. Swift does not join them, and the reason is the resolver
rather than a preference.

SwiftPM resolves a dependency's version from **bare semver tags only** — it does not read the
`python/vX.Y.Z` or `go/vX.Y.Z` prefixes the monorepo uses. The monorepo's bare tags `v0.1.0`
through `v0.6.0` belong to the *legacy* Python SDK, the one that predates the rewrite. A
`from: "0.1.0"` against that repository resolves to `v0.6.0`: `main.py`, `pyproject.toml`, `src/`,
and no Swift at all.

## The contract lives in one place

Everything this SDK is checked against — the error taxonomy, the golden responses, the literal SSE
bytes — is the same corpus Python, Go and Rust replay. It is a **git submodule**, not a copy:

```
Corpus/spec/errors.json          the error taxonomy, mapped by every SDK
Corpus/spec/cases/manifest.json  the contract cases, replayed by every SDK
Corpus/spec/fixtures/            the recorded bodies and wire bytes
```

```bash
git clone --recurse-submodules https://github.com/Root1V/axonium-sdk-swift
# or, in an existing clone:
git submodule update --init
```

A plain clone leaves `Corpus/` empty. The suite **fails** in that case rather than skipping, on
purpose: a run that passes by finding no cases proves nothing, and would report green on a
contract it never read.

## What is tested today

```
swift test
```

| Suite | What it holds |
|---|---|
| Error catalog parity | Every suffix in `errors.json` maps to an `ErrorKind`, with the catalogued retryability, in both directions. An unknown suffix falls back by status rather than failing. |
| Error envelopes | All 14 gateway error cases and all 8 token-endpoint cases in the manifest, decoded from the recorded bodies. |

## Requirements

Swift 6, strict concurrency, no warnings. macOS 14, iOS 17, iPadOS 17, visionOS 1, watchOS 10.
No dependencies beyond Foundation, Security and CryptoKit.

## Licence

MIT, the same as the monorepo.

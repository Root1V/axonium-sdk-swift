# Changelog

## Unreleased

### M0 — the contract layer

- `ErrorKind`, covering every suffix in `spec/errors.json`, with retryability, and a status-keyed
  fallback so a suffix this build does not know is still a typed error rather than a parse
  failure.
- `APIError`, `OAuthError` and `AxoniumError`, conforming to `CustomStringConvertible` and
  `LocalizedError` so they can be shown in a UI.
- `ProblemDetails`, decoding both envelopes and choosing between them by **shape rather than
  status** — a 4xx from the token endpoint is an OAuth2 outcome and never worth retrying, a 5xx
  there is the gateway failing and often is.
- `RateLimitSnapshot`, from headers, with the body fallback for `scope`.
- The contract corpus as a submodule, and a loader that raises rather than skips when it is
  absent.

Everything is `Sendable` and builds under Swift 6 strict concurrency with no warnings.

### Corpus bumped to 2026-09-27

The submodule now pins `931e615`: guide revision `2026-09-27`, 32 catalogued errors, manifest v19.
The parity guard refused the bump until both new types were mapped, which is what it is for:

    capacity-exhausted is in spec/errors.json but this SDK maps no kind for it
    predict-backend-rejected is in spec/errors.json but this SDK maps no kind for it

- `ErrorKind.capacityExhausted` — every replica busy rather than broken, retryable.
- `ErrorKind.predictBackendRejected` — the pass-through route keeps the engine's status, so the
  name claims no cause and `ErrorKind.isRetryable` cannot answer for it. `APIError.isRetryable`
  reads the status instead, and the engine's own body is reachable through `backendError`.

That second one forced the parity guard to build a whole `APIError` rather than ask the kind, and
it forced `APIError` to carry the body at all.

- `JSONValue` — a `Sendable`, `Hashable` JSON tree, and `APIError.raw`. The other three SDKs have
  always kept the decoded body so a field they do not model stays reachable; this one could not,
  because `[String: Any]` is neither `Sendable` nor `Hashable`, and an unsendable error is
  unusable across the actor boundary errors actually travel over.

**And the mutation that survived at M0 now dies.** Removing the header fallback and replaying the
corpus:

    error-correlation-ids-only-in-the-headers: request_id present is false, expected true

### Corrected

**The separate repository is a decision, not a constraint, and M0 shipped saying otherwise.**

`Package.swift` and `README.md` both claimed SwiftPM left no choice. What SwiftPM actually forbids
is a manifest in a subdirectory — a `swift/Package.swift` beside `go/` cannot be consumed. A
manifest at the monorepo *root* with `path: "swift/Sources/Axonium"` resolves and builds; measured
by doing it. The earlier reasoning assumed `from: "0.1.0"` would resolve to the legacy `v0.6.0`,
which mistakes "highest tag that exists today" for "highest tag in the range": publishing the
Swift package publishes a higher tag, and that is the one that wins.

The decision stands on reasons that survive: it is the reversible direction, the monorepo's bare
tag line is shared with the legacy Python releases, and a consumer vendors the whole tree. Those
are in README.md now, in place of the claim that there was no alternative.

### Found while building it

**A behaviour the three existing SDKs fixed is pinned by nothing.**

On 2026-09-27 all three learned to read `X-Request-ID` and `X-Trace-ID` from the response headers
when the body has none — a real case, because a validation failure forwarded from an engine has
neither id in its body and both in its header, and an error nobody can correlate is an error
nobody can report. The fix landed with three hand-written tests, one per language, and **nothing
in the shared corpus**.

Measured here by removing the header fallback from this SDK and replaying all 14 gateway error
cases: **every one still passed.** A fourth SDK built against the corpus alone would reintroduce
the bug and the suite would say it was fine.

Reported upstream as a missing contract case.

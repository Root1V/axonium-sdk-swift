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

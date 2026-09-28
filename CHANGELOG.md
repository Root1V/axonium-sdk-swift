# Changelog

## Unreleased

The runner asserts what the SDK **sent**, not only what came back, and the corpus is at v22.

Manifest v22 added `expect.request_headers` and `expect.request_headers_absent`. The second
direction is the one worth having: a key the SDK **invents** makes a retry replay a stale result
instead of generating, and an instance pin nobody asked for takes the caller out of load
balancing and out of failover. Neither is visible in any response. Mutated in all three
directions:

    the key never reaches the wire     -> sent Idempotency-Key=nothing, expected k
    the SDK invents a key              -> sent Idempotency-Key=inventada, which nobody asked for
    the SDK invents an instance pin    -> sent X-Prometheus-Instance=#1, which nobody asked for

`IdempotencyKeyTests` shrank rather than went. The part v22 replaced — the key reaching the wire
on both a completion and a stream — is gone, in the commit that put the replacement to work. Two
things stayed, and one of them only after measuring:

- **A streamed replay is still not pinned by the corpus.** `chat-idempotent-replay` asserts
  `meta.idempotent_replay`; `stream-idempotent-replay` asserts content, chunks, usage and the
  sent key, but nothing about the replay flags. Dropping the meta from the stream path entirely
  leaves all 44 cases green. Reported upstream.
- An over-long key being refused **before** a request is not expressible as a contract case at
  all: the assertion is that no request happens, and a case describes a request and its answer.


**A stream refused before it begins is now reopened, and the corpus is what found that it was not.**

The runner learned two things the manifest gained in v20: a case can serve an ordered *sequence* of
responses, and it can assert `expect.requests` — how many requests the server actually counted.
Bumping the corpus from v19 to v21 then failed on the first run:

    stream-retried-when-rejected-before-it-begins: threw ... rate limit ... 60 RPM

Recognising the rejection was already there since M1. Reopening was not, and nothing here would
have noticed: this SDK's own tests asserted that the refusal throws, which it did. Being held to
somebody else's cases is the point.

`openStream` now retries, and only where retrying cannot mean a second generation: on a stream an
error is observable **only** from the status line, before a byte of body exists, so a `4xx`/`5xx`
there means nothing was generated and nothing was billed. Once the `200` is committed the only
channel left is in-band, and that one is never retried.

Also in this change:

- The contract runner builds its client with the SDK's **default** retry policy. It passed `.none`,
  which was a harness convenience until a case began counting requests — at which point the policy
  became part of what the case measures. A runner overriding it would report "this SDK does not
  retry" about an SDK that does.
- The two error cases whose operation is a stream are replayed **through the client**, not only
  decoded. Decoding proves the envelope and says nothing about whether `chatStream` throws instead
  of yielding nothing, which is their entire purpose.

### Removed

`StreamRejectionTests`, in the same commit that put its replacement to work. It was written as a
stopgap for a corpus with no case for a pre-start refusal and said so in the file; v21 has two,
replayed through the real client, and mutation confirms they catch what it caught. A stopgap kept
past its replacement is a second copy of the truth.

The idempotency tests moved to `IdempotencyKeyTests` rather than going with it: the corpus still
does not pin that the key reaches the wire.


**The test that catches an invented error suffix did not catch an invented error suffix.**

It checked a hand-maintained array of the suffixes `ErrorKind.init` claims to resolve. That array
sat beside the initialiser, so the same hand edited both — and the one thing it guards against is
the one thing that hand forgets. Measured:

    added `case "inventado-por-mi"` to the initialiser and not to the array
      -> 19 tests, all green

The array is gone. The list is now read out of `ErrorKind.swift` at test time, which is blunt and
is the only version that cannot drift. A second test guards the reading itself, because a pattern
that matches nothing returns an empty list and every check above it passes against one.

Found because a sibling SDK hit the identical shape the same day: a `suffix -> kind` table in its
own contract runner that covered only what the corpus already exercised.


**A case this runner cannot read is now a failure, where it used to be a skip.**

Every replay loop selected its cases, then `continue`d past any it could not parse. Each suite
collects problems and asserts the list is empty — and finds none in a case it never touched, so
the suite stayed green while quietly covering less.

Measured by adding a case in the shape v20 introduced, an ordered `responses` sequence instead of
a single `response`:

    the size assertion caught it, because its counts are written by hand
    updating those counts, which is exactly what a corpus bump does -> green, case never replayed

Each loop now counts what it replayed and asserts it against what it selected, so a skip fails by
arithmetic rather than by anybody noticing. The report names the case and its keys:

    SONDA-forma-v20: this runner selected the case and cannot read it. It has no `response`
    dictionary; its keys are [expect, id, operation, request, responses]. If that includes
    `responses`, the case serves an ordered sequence and this runner has not learned that
    shape yet.

Reading that shape, and the corpus bump to v20, is the next change. This one makes the bump safe
to attempt: the failure it would otherwise produce is silence.

## 0.1.1

**`PrivacyInfo.xcprivacy`**, which Apple requires from a third-party SDK before an app embedding
it can be submitted. It was the one missing piece that blocked *shipping* rather than building.

Everything in it is empty or `false`, and each answer was checked rather than assumed. The
required-reason audit found no `UserDefaults`, no file timestamps, no disk space, no active
keyboard and no boot-time API; this package does not touch the filesystem.

`NSPrivacyCollectedDataTypes` is empty because this SDK collects nothing of its own — it
transmits what the app hands it to an address the app configures. **That is not an exemption for
the app**, and the README now says so at length, along with the two things the platform does
retain: usage rows hold counts and never content, and an `Idempotency-Key` retains the whole
response for 24 hours. The second is conditional on a choice the app makes, and is the one worth
a line in the app's own declaration.

One judgement call is written down rather than buried: `ContinuousClock` is used for token
expiry and is not on Apple's required-reason list, so no reason is declared — with the exact
entry that would be needed if a future scan disagreed.

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

### M1 — the client

`AxoniumClient`, with `chat`, `chatStream`, `models`, `modelsMine`, `embeddings`, `images`,
`rerank` and `usage`. All 40 cases of the shared manifest now replay through the real client over
`URLProtocol`, so what is under test is its own request building, header reading and
`URLSession.bytes` streaming rather than a fake sitting where the network should be.

- **Configured in code.** An app has no `.env` and no useful process environment;
  `fromEnvironment()` exists for command-line tools and is never required.
- **`ClientCredentialsTokenProvider` is an `actor`**, so ten concurrent calls on a cold client
  ask for one token rather than ten. Refresh ahead at 80% of the lifetime or under 30s, measured
  on a monotonic clock so a skewed peer cannot make a live token look expired, and the
  **granted** scope read back rather than the requested one assumed.
- **`TokenProvider` is a protocol**, so an app can run in governed mode and this SDK never sees
  a client secret.
- **A private CA as data**, appended to the system anchors and still evaluated. No path returns a
  credential without `SecTrustEvaluateWithError` succeeding, which is the shape every "just
  disable verification for dev" bug takes.
- Streams cancel cooperatively, carry their partial content through a failure, reassemble tool
  calls from fragments that are individually invalid JSON, and derive usage from `timings` when
  no frame reported any — marked `estimated`, so nobody bills against a guess.

### Found while building it

**Two behaviours the corpus does not pin**, both discovered by mutation rather than by reading:

    the stream stops checking the status before parsing  -> all 40 cases still passed
    the idempotency key never reaches the wire           -> all 40 cases still passed

The first is the one that matters. Since `PRM-143` a streamed request refused *before* the stream
begins returns the engine's real status, and an SDK that starts parsing SSE because it asked for
a stream turns every refusal into a silent empty answer. Nothing in the manifest exercises it.
Reported upstream; `StreamRejectionTests` holds the line here meanwhile — which is the same
half-measure that let the correlation-id bug come back, and is written down as such.

**And the test harness had a race of its own.** `StubProtocol` keyed its stubs by path alone, and
Swift Testing runs suites in parallel: two suites answered each other's requests, and a stream
test failed reading another suite's fixture. Stubs now belong to a session identified by a header,
so a test can only reach its own. Fixed rather than serialised — serialising would have hidden it
and kept the shared state.

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

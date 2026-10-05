# Changelog

## Unreleased

Nothing yet.

---

## 0.3.0 — 2026-10-04

**Minor rather than patch, because two added `ErrorKind` cases break an exhaustive `switch`.** Swift
offers a source package nothing to say *this will grow* with: `@frozen` and its absence are
instructions to a module built with library evolution, which a SwiftPM source dependency is not. So
every row the platform adds to its catalogue is a compile error for a caller who covered all the
cases, and the only defence is theirs to write — a `default` arm. Rust reached the same release for
the same reason today and could at least mark the type `#[non_exhaustive]` so it was the last time;
this package cannot, and says so in the README rather than leaving it to be discovered.

**The corpus submodule moves from v26 to v27, 49 cases**, and the replay passed on the first run. The
new case is a second in-band stream failure whose payload is an **object** rather than the literal
string `stream interrupted` — authored in the monorepo because mutating a runner to compare that exact
text left all 48 cases green, so the corpus could not tell *detect the key* from *compare the string*.
This SDK had always detected the key; what changed is that it is now pinned rather than lucky.

What the bump did cost is the one test that writes the counts down — 48 → 49 and `stream_error` 2 → 3
— and that is the test doing its job. **It is also the only place in five SDKs where a shrinking
corpus would be noticed**: Python, Go and Rust replay whatever the manifest holds and report a pass
either way. Swift and TypeScript pin the total; the other three do not.

Corpus at `2026-10-02 · PRM-167/173/174`, which adds two error types:

- **`404 unknown-route`** → `ErrorKind.unknownRoute`
- **`405 method-not-allowed`** → `ErrorKind.methodNotAllowed`

`unknown-route` is deliberately **not** `notFound`, and the platform split them because all four
SDKs dispatch on the suffix: `not-found` is a statement about *data* — no usage row with that id
belonging to this client — which a caller may read as an empty result or retry. A bad URL is neither.

The catalog-parity test earned its keep without being touched. Adding the two kinds against the old
32-row catalog failed `no mapped suffix is absent from the catalog`, naming both — which is the test
refusing to let this SDK invent a suffix that would send a caller to catch a case that never arrives.

---

## 0.2.0 — 2026-10-02

### §2.7 moved the axis, and the answer in the previous entry was to the wrong question

**Read this before the entry below it, which it partly reverses.** Guide revision `2026-10-01`
rewrites §2.7 from "Client types — who may hold a credential" to "Credentials — whose they are, and
who issues them", and the criterion is no longer *where the secret sits*:

> **A credential identifies whoever pays for consumption.**

So the shape this package spent a release talking itself out of is **supported**, for the case that
matters to the app that asked:

| Whose credential | In an App Store app? | Why |
|---|---|---|
| The integrator's | No | A copy on every device is a copy of the identity holding the grants and paying the invoice |
| **The end client's own** | **Yes, Keychain included** | The principal, the grants and the bill are theirs; a leak costs them their own account |

An app with a credential in it is still a public client in RFC 8252's terms. That is accepted here
when the secret and the bill belong to the same person — the distinction the previous version did
not draw, and the reason it reached the wrong conclusion from correct premises.

Two consequences an app has to be built around, both new in §2.7 and neither a code change:

- **One credential per client, not per device.** The same secret on a Mac and an iPhone is the
  normal case, not a leak. Revocation is per client.
- **Issuance is always a human administrator.** No registration endpoint, and none planned, because
  issuing a credential opens a billing account. **"No credential yet" is where every new user
  starts** — a first-class state in the app rather than an error, and the request goes to the
  platform, not to the integrator.

Corrected in all three places that stated the old rule: `AxoniumClient`'s headline doc,
`AxoniumConfiguration`, and the README's "Where the credential lives", which is now a table because
the answer has two rows and one of them had been written as "no".

**No behaviour changed in either direction.** This package takes a credential or a `TokenProvider`
and always did; what was wrong was only what it told a reader to do. The `TokenProvider` seam still
pays for itself — nothing about how a token was obtained is this package's business, so none of
these reversals can reach the public API.

### The corpus replaced two of this release's own tests

`Corpus` moves to manifest **v26, 48 cases**, which adds four on the pass-through route: the three
live engine shapes and the first recorded `predict-backend-rejected`.

Two hand-written tests added earlier in this same release are **gone**, replaced in the commit that
vendored the cases rather than against a promise of one:

    "a top-level array answer survives"  ->  predict-classification-answers-a-top-level-array
    "an object answer survives too"      ->  predict-zero-shot… + predict-typed-decision…

The corpus versions are strictly better: recorded wire bytes rather than bodies shortened by hand,
and four SDKs replay them instead of one. Mutation confirms the replacement has the same teeth —
decoding the body as a dictionary fails `predict-classification` and nothing else, the identical
single failure the hand-written test produced.

What stays in `VisionAndPredictTests` is what a corpus case cannot express: three refusals whose
assertion is that **no request happens**, and one about what goes out rather than what comes back.

Both corpus-coverage guards earned their keep on the bump: the size guard named `48 != 44`, and
"this SDK implements every operation the manifest exercises" named `predict.create` before any field
mismatch could bury it.

### Also in this release

The three sections that follow, unreleased until now: vision through `MessageContent`, the
pass-through route, the catalog documentation fixed after `PRM-167`, the stream-retry unification,
and `PrivacyInfo.xcprivacy`.

### Vision, and the pass-through route

Both built against a live deployment rather than against the guide, and both verified end to end
before anything was written down — an 8×8 PNG, half red and half blue, came back described
correctly, and the three `predict` engines answered their three different shapes.

**`Message.content` is now `MessageContent`, a union of text or parts.** This is a breaking change
and it is the right one: the wire has one field with two shapes, OpenAI and Anthropic model it
that way, and Python, Go and Rust in this family all accept either. Swift shipped `String?` and
was the only one of the four that could not send an image.

An earlier proposal here was a second `parts` field beside `content`, with both-set rejected at
runtime. That was worse and was chosen for the wrong reason — to avoid breaking one consumer. A
union makes the meaningless state unrepresentable instead of validated, which is the entire
advantage of having enums.

`ExpressibleByStringLiteral` keeps `content: "hola"` exactly as it was, and a text message still
serialises as a bare string rather than a one-element array.

**Images are bytes and never a link.** `ContentPart` has no case for a URL, because the gateway
refuses `http(s)://` as an SSRF mitigation — an API accepting one would accept something that
always fails. Python enforces that with a validator that raises; here the type cannot express it.

**`predict(model:body:)` returns a `JSONValue`, not a dictionary.** Measured: `sst2-clf` answers
with a **top-level array**, while the other two answer with objects of different shapes. A client
reading every body as a dictionary reports "not JSON" about valid JSON. It is deliberately not a
`classify(text:)` typed per modality — the shape belongs to the engine, and `payloadSchema` in the
catalog is what identifies it.

`sendRaw` is the one retry loop read two ways, so the pass-through route and the modelled
endpoints cannot drift apart in how they retry.


**The documented example was the shape the platform has now said not to build.**

Guide §2.7 answers the question this package raised as `A-30`: a `client_id` is the principal that
model grants and billing rows are keyed to, so a `client_secret` inside an App Store binary is the
integrator's identity — the one holding the grants and paying the invoice — copied onto every
user's device. The keychain is the right place for a credential and the wrong place for that one.
mTLS was never the answer: a certificate inside a downloadable app is a secret inside a
downloadable app. PKCE is not either, and not on cost — per-end-user identity has nowhere to live
in the platform's authorization model.

Nothing in this package's behaviour changes. What changes is what it tells a reader to do:
`clientSecret: secretFromKeychain` was the headline example in the README and in
`AxoniumClient`'s own doc, and it is now the second example, for a machine the integrator
controls. `TokenProvider` is the first — documented as the recommended path rather than as an
escape hatch, with a worked example of a provider backed by the app's own backend.

And it is worth saying why that seam pays off twice. The argument for deciding the credential
question early was that a Swift package gaining a `SecIdentity` in v2 breaks public API in a
binary that goes through review. With a token as the entire surface, that break cannot happen:
nothing about how a token was obtained is this package's business.


The catalog docs described an endpoint that no longer exists.

`PRM-167` did more than close `GET /v1/models` to anonymous callers: it now returns only the
models the token holds `model:<id>` scope for, which makes `modelsMine()` an **alias** of it. This
SDK's behaviour was already correct — it always authenticated — and everything it said about the
endpoint was not. "The public catalog", "needs no token", "the honest connectivity check": none of
the three survived.

The fact worth having in the doc is one this session got wrong by inference before the guide
stated it: **an empty list means no grants, not an empty platform.** Two different facts, only an
operator can tell them apart, and guessing the second is how somebody concludes a deployment is
broken when their token simply has nothing granted.

And the platform now names `modelsMine()` as what belongs behind a "test connection" button,
because it proves three things at once — the gateway answers, the credential works, and there is
something this caller may send. `GET /health` proves that a process replied.


Corpus to **v25**, which pins that the catalog is authenticated.

`request_headers_present` is a third form beside the two from v22: by name, no value, because
`Authorization` carries each runner's own test token and comparing it would pin the fixture rather
than the behaviour. It is an assertion added to an existing case rather than a new one — no
recording can carry a fact about the *request*.

Swift never had the defect: `models()` has always gone through the authenticated path. It is
pinned now anyway, which is the difference between being right and being held to it:

    skip Authorization on /v1/models
      -> catalog-list: sent no Authorization header; this endpoint is authenticated like
         every other one, whatever the guide says


Corpus to **v23**, which puts the streamed replay flag into the contract. The capability this
runner built for it a commit earlier is what reads the new assertion, so the bump was a step
rather than work:

    the stream path drops its meta -> stream-idempotent-replay: meta.idempotent_replay was false

`IdempotencyKeyTests` shrank again, to the pair v23 could not reach. Not an oversight upstream:
that case's recorded response carries only `Idempotent-Replay`, while its chat sibling also
captured `X-Request-ID` and `X-Idempotent-Replay-Of`. Asserting those needs a new capture, not a
new assertion — an expectation written against bytes that do not contain them would be invented.


**Two defects the Mundus team found by reading the tag, and the guards that would have caught them.**

- **The `User-Agent` announced `0.1.0` from `0.1.1`.** A literal beside the header that sends it,
  so every diagnostic a gateway operator ran by version counted its users as being on a release
  they were not on. The number now lives once, in `axoniumVersion`, and a test fails when it falls
  **behind** the newest git tag. Behind rather than different: between releases it is legitimately
  ahead, and a check that is red by design gets ignored.
- **A doc comment pointed at a typed `chat(_:as:)` layer that was never written.** The compiler
  has nothing to say about a name inside a comment, so it cost a reader the time to go looking —
  which is the whole damage an invented API name does. The doc now says what actually happens:
  decode the JSON string yourself, and check `finishReason` first.

A guard now resolves every ``symbol`` reference in the sources against the declared signatures.

**Its first version would not have caught the bug it was written for**, which is worth recording.
It compared the base name before the `(`, and `chat` exists — only that signature does not.
Measured by reintroducing the exact reference and watching 23 tests stay green. It compares
argument labels now:

    ``AxoniumClient/chat(_:as:idempotencyKey:instance:)`` -- no such signature.
    `chat` exists as: chat(_:idempotencyKey:instance:)

Three false positives were fixed on the way, each of which would have got the check muted rather
than read: enum cases with associated values are declarations DocC refers to (`api(_:)`), a
wrapped declaration swallowed the `///` lines inside it and yielded `init(///:///:clientSecret:)`,
and a default value is itself a call — `timeouts: Timeouts = Timeouts()` truncated the client's
initialiser to five labels of eight.


**A streamed case can assert `meta`, which no runner in this family could do.**

A peer measured it across the other three: of nine streamed cases in the corpus, zero can assert
`expect.fields` in any runner — the non-streaming branch has always had it, the streamed branch
never did. So `request_id`, `trace_id`, `rate_limit` and both replay flags were unassertable on a
stream, and a stream dropping its entire `meta` passed all 44 cases. This runner had the same
gap, and would have ignored such a case in silence.

The stream branch now resolves `fields` against the stream, `meta.*` only: content, chunks, usage
and tool calls already have dedicated keys, and a second spelling of one assertion is how two
spellings drift. Verified by adding the assertion the corpus is missing and re-running:

    stream-idempotent-replay asserting meta.idempotent_replay_of
      -> read, compared, and reported — the capability works

A new guard names, per `kind`, every key a streamed case may assert, so the next addition the
runner does not read fails here instead of passing quietly.

One detail the probe turned up, for whoever fills the gap upstream: the streamed replay case's
recorded response carries only `Idempotent-Replay: true`. Its chat sibling also carries
`X-Request-ID` and `X-Idempotent-Replay-Of`. Asserting `_of` on the streamed one needs a new
recording, not just a new assertion.


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

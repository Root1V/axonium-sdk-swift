# Roadmap

The order is deliberate, and the first two steps are the ones that look like overhead and are not.

## M0 — the contract, before the client · **done**

Repository, corpus submodule, the error taxonomy, and the tests that hold the two together.

Building the client first is the tempting order and the wrong one. The claim this SDK has to earn
is *parity*, and parity is not something you add at the end — it is a corpus you are held to from
the first commit. Starting here also means the runner exists before there is any code to excuse.

## M1 — MVP · **done**

- `AxoniumConfiguration`: code-first, no environment variables required. An app on macOS or iOS
  has no `.env` and no process environment worth reading, so every setting must be passable in
  Swift, including the timeouts and the retry policy.
- `TokenProvider` protocol + a `client_credentials` actor: refresh ahead at 80% of the TTL or when
  under 30s, one refresh at a time, one reactive retry on `401 token-expired`, and the **granted**
  scope read back from the response rather than the requested one assumed.
- `chat`, `chatStream` (`AsyncThrowingStream`, cooperative cancellation), `models`, `modelsMine`.
- Errors: already here.
- Retries: `RetryPolicy` per guide §6.2.
- A custom CA as **data**, via `SecTrustSetAnchorCertificates`. No insecure mode.

`GET /health` is deliberately **not** in M1. It answers `{"status":"ok"}` and has no contract in
the platform guide — no documented shape, no documented failure, and no SDK implements it. A
"Test connection" button backed by it would go green on a gateway whose model registry is empty.
`GET /v1/models` is in the contract, needs no token, and failing it means something. The question
of whether `/health` gets a contract is open with the platform team.

## M2 — parity

Embeddings, rerank, images, usage and rate-limit snapshots landed with M1 — they are in the
corpus, and leaving them out would have meant a runner that skips cases. What is left:

- `TokenClaims` surfaced on the client rather than only as a type.
- **Teach the contract runner an ordered response *sequence*** (`responses`) and the
  `expect.requests` count, then bump the corpus to v20. Two cases need it, both about stream
  retries — see below. Until then the corpus stays pinned below v20, because a runner that reads only
  `case["response"]` would skip or misreport them.
- **Reopen a stream rejected before it begins**, per the decision below. The status check is already
  there; the retry is not.
- `X-Prometheus-Ignored-Parameters`, once the four SDKs decide it together.
- `predict(model:body:)` for the pass-through route, which no SDK implements yet.

## M3 — 1.0

100% of the corpus, DocC, `PrivacyInfo.xcprivacy`, iOS CI.

## Not inherited without a decision

One place left where matching the other three is a choice rather than a default:

- **`X-Prometheus-Ignored-Parameters`.** Implemented in none of them.

## Decided — stream retries

Settled on 2026-09-27 (`AXO-111` in `Root1V/axonium-sdk`, agreed in `A-02`), so the behaviour was
decided rather than inherited. The tie was real: Python made one attempt, Go and Rust made three, and
all three documented never retrying.

- **A rejection that arrives *instead of* the stream is retried like any other request**, honouring
  `Retry-After`. The gateway reads the engine's status before the `200`/`text/event-stream` headers
  exist, so nothing was generated and nothing was billed, and reopening is a first generation rather
  than a second. It is also the only retry there is: the gateway performs no internal retries on a
  streamed request, so a `503 backend-unavailable` arrives after one attempt rather than three.
- **A stream that has already begun is never retried.** The failure arrives in band, part of the
  answer was delivered, and part was billed. No exceptions in any of the four.

Only expressible since `PRM-143`: before it, a stream rejected before starting came back as a `200`
whose body was nothing but `data: [DONE]`, indistinguishable from a legitimately empty answer.

`chatStream` already reads the status before parsing SSE, so the rejection is recognised; what the
retry adds is reopening it.

Manifest **v20** pins both halves — `stream-retried-when-rejected-before-it-begins` and
`stream-not-retried-once-it-has-begun`. Both need something the corpus did not have before: a case
serving an ordered *sequence* of responses, and an `expect.requests` count of how many reached the
server. The count, not the SDK's own `attempts`, is the assertion that would have caught the
divergence — an SDK can be wrong about what it reports while the server's count is the fact.

**This runner reads `case["response"]` and knows nothing of `responses`.** The corpus is still pinned
below v20, so nothing fails yet; bumping it without teaching the runner the sequence shape would make
the two cases fail for the wrong reason, or skip silently, which is worse. See M2.

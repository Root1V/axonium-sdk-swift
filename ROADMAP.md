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
- `X-Prometheus-Ignored-Parameters`, once the four SDKs decide it together.
- `predict(model:body:)` for the pass-through route, which no SDK implements yet.

## M3 — 1.0

100% of the corpus, DocC, `PrivacyInfo.xcprivacy`, iOS CI.

## Not inherited without a decision

Two places where matching the other three is a choice rather than a default:

- **Stream retries.** Measured on 2026-09-27: Python makes one attempt, Go and Rust make three.
  All three *document* never retrying. Whatever the four settle on, they settle on it together.
- **`X-Prometheus-Ignored-Parameters`.** Implemented in none of them.

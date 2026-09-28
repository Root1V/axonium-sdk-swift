# Axonium for Swift

The Axonium SDK for the Prometheus inference platform, for macOS, iOS, iPadOS, visionOS and
watchOS.

> **Status: M1.** The client works and replays all 44 cases of the shared contract corpus. Not
> yet tagged, so it cannot be resolved as a package dependency — see [ROADMAP.md](ROADMAP.md)
> for what M2 and 1.0 add.

```swift
.package(url: "https://github.com/Root1V/axonium-sdk-swift", from: "0.1.0")
```

## Why this is a separate repository

The other three SDKs live together in [`Root1V/axonium-sdk`](https://github.com/Root1V/axonium-sdk),
under `python/`, `go/` and `rust/`. Swift does not, and this is a **decision** rather than a
constraint — which is worth saying plainly, because the first version of this file claimed the
resolver left no choice and that was not true.

**What the resolver does forbid** is the shape you would expect: a `swift/Package.swift` beside
`go/`. SwiftPM cannot consume a package that lives in a subdirectory of a repository.

```
.package(url: ".../axonium-sdk.git", from: "0.1.0")
  error: the package manifest at '/Package.swift' cannot be accessed
```

**What it permits**, and what the earlier claim missed: a manifest at the monorepo *root* with
`path: "swift/Sources/Axonium"`. That resolves and builds. `from: "0.1.0"` means
`>= 0.1.0, < 1.0.0` and SwiftPM takes the highest tag in range — which, once the Swift package is
published, is the Swift one and not the legacy `v0.6.0`.

So the reasons are these, and none of them is impossibility.

**It is the reversible choice.** Moving from a separate repository into the monorepo later is
copying files and adding a root manifest. Moving the other way is not: by then the bare semver
tag line has been spent on Swift releases, and it cannot be reclaimed without deleting published
tags.

**One failure mode exists only in the monorepo.** Its bare tags `v0.1.0` through `v0.6.0` belong
to the *legacy* Python SDK, the one that predates the rewrite. Sharing that line with Swift means
anyone pinning inside it gets the old tree and a hard error:

```
.upToNextMinor(from: "0.6.0")
  error: the package manifest at '/Package.swift' cannot be accessed
```

**And a consumer vendors what it depends on.** A monorepo dependency puts 3.0 MB of working tree
and 11 MB of git objects into an app's `.build`, of which the Swift part is 4 KB. The size is not
the argument; what an App Store binary's dependency graph contains is.

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

## Using it

```swift
import Axonium

let client = try AxoniumClient(configuration: .init(
    gatewayBaseURL: "https://gateway.example",
    clientID: id,
    clientSecret: secretFromKeychain))     // never hard-coded, never logged

let answer = try await client.chat(.init(
    model: "qwen3-0.6b",
    messages: [.system("Responde en español."), .user("¿Capital de Perú?")]))
print(answer.content ?? "")

for try await chunk in try await client.chatStream(request) {
    print(chunk.content ?? "", terminator: "")
}
```

**Configured in code.** An app on macOS or iOS has no meaningful process environment and no
`.env`; the secret comes out of the Keychain at runtime. `AxoniumConfiguration.fromEnvironment()`
exists for command-line tools and is never required.

**Everything is `Sendable`** and builds under Swift 6 strict concurrency with no warnings. The
token provider is an `actor`, so a burst of concurrent calls on an expired token produces one
token request rather than one per caller.

| | |
|---|---|
| `chat` / `chatStream` | completions, and an `AsyncSequence` with cooperative cancellation |
| `models` / `modelsMine` | the public catalog, and what this token actually holds scope for |
| `embeddings` / `images` / `rerank` | the rest of inference |
| `usage(requestID:)` | the accounting row for one request |

## What is tested today

```
swift test
```

| Suite | What it holds |
|---|---|
| Error catalog parity | Every suffix in `errors.json` maps to an `ErrorKind`, with the catalogued retryability, in both directions. An unknown suffix falls back by status rather than failing. |
| Error envelopes | All 17 gateway error cases and all 8 token-endpoint cases, decoded from the recorded bodies. |
| Contract runner | All 14 success cases, all 9 streaming cases, and the 2 error cases whose operation is a stream — replayed through the real client over `URLProtocol`. A case can serve an ordered sequence of responses and assert how many requests the server actually saw. |
| Idempotency key | The one thing the corpus still does not pin: that the key reaches the wire. Its replay case asserts on what comes back, so an SDK that never sent one would pass it. |
| Corpus coverage | That every case in the manifest is claimed by a suite. Each suite above passes against an empty selection; this is the guard on the selections. |

## Privacy

This package ships a `PrivacyInfo.xcprivacy`, which Apple requires from a third-party SDK before
an app embedding it can go to the App Store or TestFlight. It declares:

| | |
|---|---|
| `NSPrivacyTracking` | `false` — nothing here tracks, and nothing is joined with data from other apps or brokers |
| `NSPrivacyTrackingDomains` | empty |
| `NSPrivacyCollectedDataTypes` | empty |
| `NSPrivacyAccessedAPITypes` | empty — audited, not assumed: no `UserDefaults`, no file timestamps, no disk space, no active keyboard, no boot time. This package does not touch the filesystem at all. |

**Read the next part before you assume this file covers your app.**

### What this manifest does not cover

An SDK's manifest declares what **the SDK** collects. This one is a transport: it sends what
your app hands it, to a gateway address your app configures, on a platform your own organisation
operates. It keeps nothing — no cache, no cookies, no disk writes,
`URLSessionConfiguration.ephemeral` by default, and nothing is ever logged.

**Your app is the one collecting.** If a prompt contains a user's document, message, filename or
photo, your app is transmitting that, and it is your app's `PrivacyInfo.xcprivacy` that has to
say so. `NSPrivacyCollectedDataTypes` being empty here is a statement about this package, not an
exemption for the binary it ends up in.

### What the platform retains, so you can write your own declaration

Two facts, both from the platform's integration guide and verified against a deployment:

- **The usage row holds counts, never content.** `request_id`, `model`, `request_kind`, token
  counts, `cost_usd`, `instance_id`, `created_at`. No prompt, no completion, no input of any
  kind. Retained for billing.
- **An `Idempotency-Key` retains the whole response for 24 hours**, so that a retry can replay
  it instead of generating again — the SSE body included, up to 1 MiB. The key is also
  fingerprinted against the request payload.

That second one matters and is **conditional on a choice your app makes**. Sending no key means
nothing is retained beyond the request; sending one means the generated answer sits in the
platform's store for a day. Neither is wrong, but only one of them is a thing your users might
reasonably want to know about, and the SDK cannot make that call for you.

### One judgement call, written down rather than buried

`ClientCredentialsTokenProvider` measures token expiry with `ContinuousClock`, so that a skewed
peer or an NTP step cannot make a live token look expired. Apple's required-reason category for
system boot time names `systemUptime` and `mach_absolute_time()`; `ContinuousClock` is neither,
so no reason is declared for it. Declaring a spurious one would be its own false statement.

If a future App Store scan ever flags it, the fix is a single entry —
`NSPrivacyAccessedAPICategorySystemBootTime` with reason `35F9.1` — and we would rather you know
where it would go than discover the question during review.

## Requirements

Swift 6, strict concurrency, no warnings. macOS 14, iOS 17, iPadOS 17, visionOS 1, watchOS 10.
No dependencies beyond Foundation, Security and CryptoKit.

## Licence

MIT, the same as the monorepo.

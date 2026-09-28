import Foundation
import Testing

@testable import Axonium

/// The two things about streaming that the shared corpus does not pin.
///
/// Both were found by mutation: breaking them left all 40 manifest cases passing. They are
/// written here as hand-written tests, which is the same half-measure the other three SDKs took
/// for the correlation-id fallback — and that one came back. The corpus gap is reported upstream;
/// these hold the line until it closes.
struct StreamRejectionTests {

    private func client(_ stubs: StubProtocol.Session) throws -> AxoniumClient {
        try AxoniumClient(
            configuration: .init(
                gatewayBaseURL: "https://gateway.test", clientID: "id", clientSecret: "secret",
                retry: .none, sessionConfiguration: stubs.configuration))
    }

    /// A streamed request refused **before** the stream begins must throw, with the real status.
    ///
    /// The gateway reads the engine's status before committing the `200`/`text/event-stream`
    /// headers, so a request the engine refuses comes back as an ordinary error response — the
    /// engine's own status and its OpenAI-shaped body, exactly as the non-streaming form of the
    /// same endpoint returns it. Setting `stream: true` does not buy a different error contract.
    ///
    /// Until `PRM-143` (2026-09-27) this case arrived as a `200` whose body was nothing but the
    /// terminal frame, which no caller could tell from a legitimately empty answer. An SDK that
    /// starts parsing SSE on the strength of having asked for a stream turns every refusal into
    /// a silent empty result.
    @Test("a stream refused before it begins throws with the engine's status, not an empty answer")
    func rejectionBeforeTheStreamBegins() async throws {
        let stubs = StubProtocol.Session()
        stubs.stubToken()
        stubs.stub(
            path: "/v1/chat/completions",
            .init(
                status: 400,
                headers: ["Content-Type": "application/json", "X-Request-ID": "req-400"],
                body: Data(
                    #"{"error":{"code":400,"message":"Unable to generate parser for this template","type":"invalid_request_error"}}"#
                        .utf8)))

        do {
            let stream = try await client(stubs).chatStream(
                .init(model: "qwen3-0.6b", messages: [.user("hi")]))
            var frames = 0
            for try await _ in stream { frames += 1 }
            Issue.record("the stream yielded \(frames) frames; a 400 must throw before the first")
        } catch let AxoniumError.api(error) {
            #expect(error.status == 400)
            // The body is the engine's, so there is no `type` to key on. Falling back by status
            // is right; inventing a suffix or refusing to parse would both be wrong.
            #expect(error.kind == .otherClientError)
            // And the id is there, in the header, which is the only place this body has one.
            #expect(error.requestID == "req-400")
        }
    }

    /// A connection the gateway could not open is a `503` in the problem+json envelope.
    ///
    /// The other half of the same change, and the half that is retryable: nothing was generated
    /// and nothing was billed. In streaming the gateway performs no internal retries, so this
    /// arrives after one attempt rather than three — the client is the only retry there is.
    @Test("a stream whose backend was unreachable is a typed, retryable 503")
    func backendUnavailableBeforeTheStream() async throws {
        let stubs = StubProtocol.Session()
        stubs.stubToken()
        stubs.stub(
            path: "/v1/chat/completions",
            .init(
                status: 503,
                headers: [
                    "Content-Type": "application/problem+json", "X-Request-ID": "req-503",
                ],
                body: Data(
                    #"{"type":"https://prometheus.internal/errors/backend-unavailable","title":"Backend Unavailable","status":503,"request_id":"req-503"}"#
                        .utf8)))

        do {
            let stream = try await client(stubs).chatStream(
                .init(model: "qwen3-0.6b", messages: [.user("hi")]))
            for try await _ in stream {}
            Issue.record("a 503 must throw rather than yield an empty stream")
        } catch let AxoniumError.api(error) {
            #expect(error.status == 503)
            #expect(error.kind == .backendUnavailable)
            #expect(error.isRetryable)
        }
    }

    /// The idempotency key has to reach the wire, on a stream as much as on a buffered call.
    ///
    /// Worth a test of its own because the corpus checks only what comes *back*: its replay case
    /// asserts on the response headers, so an SDK that never sent a key would still pass it.
    @Test("the idempotency key reaches the wire on both a stream and a completion")
    func idempotencyKeyIsSent() async throws {
        for streaming in [false, true] {
            let stubs = StubProtocol.Session()
            stubs.stubToken()
            stubs.stub(
                path: "/v1/chat/completions",
                .init(
                    status: 200,
                    headers: [
                        "Idempotent-Replay": "true",
                        "X-Idempotent-Replay-Of": "original-1",
                    ],
                    body: streaming
                        ? Data("data: [DONE]\n\n".utf8)
                        : Data(#"{"choices":[{"index":0,"message":{"content":"hi"}}]}"#.utf8),
                    isEventStream: streaming))

            let request = ChatRequest(model: "qwen3-0.6b", messages: [.user("hi")])
            let meta: ResponseMeta
            if streaming {
                let stream = try await client(stubs).chatStream(request, idempotencyKey: "key-1")
                for try await _ in stream {}
                meta = stream.meta
            } else {
                meta = try await client(stubs).chat(request, idempotencyKey: "key-1").meta
            }

            let sent = stubs.requests(to: "/v1/chat/completions").first
            #expect(
                sent?.headers["Idempotency-Key"] == "key-1",
                "streaming=\(streaming): the key never reached the wire")
            // A replay was neither generated nor charged, and the same call site produces both,
            // so a caller has to be able to tell which one they got.
            #expect(meta.idempotentReplay, "streaming=\(streaming): the replay was not flagged")
            #expect(meta.idempotentReplayOf == "original-1")
        }
    }

    /// A key longer than the gateway accepts fails here, before a round trip is spent on it.
    @Test("an over-long idempotency key is refused locally")
    func overLongKeyIsRefused() async throws {
        let stubs = StubProtocol.Session()
        stubs.stubToken()
        stubs.stub(
            path: "/v1/chat/completions", .init(status: 200, headers: [:], body: Data("{}".utf8)))

        await #expect(throws: AxoniumError.self) {
            _ = try await client(stubs).chat(
                .init(model: "m", messages: [.user("hi")]),
                idempotencyKey: String(repeating: "k", count: 256))
        }
        #expect(
            stubs.requests(to: "/v1/chat/completions").isEmpty,
            "the request was sent anyway, which is the round trip this check exists to save")
    }
}

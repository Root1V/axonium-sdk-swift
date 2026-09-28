import Foundation
import Testing

@testable import Axonium

/// The idempotency behaviour the shared corpus still does not pin.
///
/// This file used to also hold the two stream-rejection tests. Those are gone, and their going
/// is the point: they were written as a stopgap for a corpus that had no case for a streamed
/// request refused before the stream begins, and said so in as many words. Manifest v21 added
/// `stream-rejected-before-it-begins-is-an-error` and its retryable sibling, both replayed
/// through the real client by `ContractRunnerTests.streamedErrorCases`, and mutation confirms
/// they catch what these caught. A stopgap kept past its replacement is just a second copy.
///
/// What remains is genuinely unpinned. The corpus has a replay case, but it asserts on what
/// comes *back* — an SDK that never sent an `Idempotency-Key` would pass it.
struct IdempotencyKeyTests {

    private func client(_ stubs: StubProtocol.Session) throws -> AxoniumClient {
        try AxoniumClient(
            configuration: .init(
                gatewayBaseURL: "https://gateway.test", clientID: "id", clientSecret: "secret",
                retry: .none, sessionConfiguration: stubs.configuration))
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

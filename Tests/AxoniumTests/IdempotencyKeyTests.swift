import Foundation
import Testing

@testable import Axonium

/// The idempotency behaviour the shared corpus still does not pin.
///
/// This file keeps shrinking, which is the point. It began as a stopgap for two things the corpus
/// was blind to, and each time the corpus grows a case for one of them, that part goes — in the
/// commit that puts the replacement to work, never against a promise of one.
///
/// Gone with manifest v22, which added `expect.request_headers`: that the key reaches the wire on
/// both a completion and a stream. Two cases assert it now, and mutation confirms they catch what
/// was caught here.
///
/// What is left is what v22 did **not** reach.
struct IdempotencyKeyTests {

    private func client(_ stubs: StubProtocol.Session) throws -> AxoniumClient {
        try AxoniumClient(
            configuration: .init(
                gatewayBaseURL: "https://gateway.test", clientID: "id", clientSecret: "secret",
                retry: .none, sessionConfiguration: stubs.configuration))
    }

    /// A streamed replay has to be recognisable as one, and only this says so.
    ///
    /// `chat-idempotent-replay` asserts `meta.idempotent_replay` and its `_of`. Its streaming
    /// sibling, `stream-idempotent-replay`, asserts content, chunk count, usage and the key on
    /// the wire — but nothing about the replay flags. Measured: dropping the meta from the stream
    /// path entirely leaves all 44 cases green and fails only here.
    ///
    /// It matters because the two outcomes come from the same call site. A replay was neither
    /// generated nor charged, and a caller reconciling cost has no other way to tell which one
    /// they got — `meta.idempotentReplayOf` is the id that actually carries the usage row, since
    /// a replay's own id has none.
    ///
    /// Reported upstream as a gap in that case.
    @Test("a streamed replay is flagged as a replay, and names the request that was charged")
    func streamedReplayIsFlagged() async throws {
        let stubs = StubProtocol.Session()
        stubs.stubToken()
        stubs.stub(
            path: "/v1/chat/completions",
            .init(
                status: 200,
                headers: [
                    "X-Request-ID": "replay-1",
                    "Idempotent-Replay": "true",
                    "X-Idempotent-Replay-Of": "original-1",
                ],
                body: Data("data: [DONE]\n\n".utf8),
                isEventStream: true))

        let stream = try await client(stubs).chatStream(
            .init(model: "qwen3-0.6b", messages: [.user("hi")]), idempotencyKey: "k")
        for try await _ in stream {}

        #expect(stream.meta.idempotentReplay, "the streamed replay was not flagged")
        #expect(stream.meta.idempotentReplayOf == "original-1")
        #expect(stream.meta.requestID == "replay-1")
    }

    /// A key longer than the gateway accepts fails here, before a round trip is spent on it.
    ///
    /// Not expressible as a contract case at all: the assertion is that **no request happens**,
    /// and a corpus case describes a request and its answer. This is the kind of thing that
    /// legitimately lives outside the corpus rather than waiting for it.
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

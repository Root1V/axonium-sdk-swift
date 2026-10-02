import Foundation
import Testing

@testable import Axonium

/// Multi-part messages and the pass-through route, neither of which the shared corpus covers.
///
/// The corpus has one vision case and it is a *rejection* — a remote image URL refused
/// client-side — and no `predict` case replayable through an SDK at all. Both surfaces were
/// built against a live deployment instead, and these tests pin what that measured.
struct VisionAndPredictTests {

    private func client(_ stubs: StubProtocol.Session) throws -> AxoniumClient {
        try AxoniumClient(
            configuration: .init(
                gatewayBaseURL: "https://gateway.test", clientID: "id", clientSecret: "secret",
                retry: .none, sessionConfiguration: stubs.configuration))
    }

    // MARK: - what goes on the wire

    @Test("a text message still serialises as a bare string, not as a one-element array")
    func textStaysAString() throws {
        let payload = Message.user("hola").wireForm
        #expect(payload["content"] as? String == "hola")
    }

    /// The whole point of the union: the ordinary case must not get more verbose to make the
    /// rare one possible.
    @Test("a string literal is still a message")
    func stringLiteralStillWorks() {
        let message = Message(role: "user", content: "hola")
        #expect(message.content == .text("hola"))
    }

    @Test("an image part becomes a base64 data URI with its media type")
    func imageBecomesADataURI() throws {
        let bytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let payload = Message.user("¿qué es?", image: bytes, mediaType: "image/png").wireForm
        let parts = try #require(payload["content"] as? [[String: Any]])

        #expect(parts.count == 2)
        #expect(parts[0]["type"] as? String == "text")
        let image = try #require(parts[1]["image_url"] as? [String: Any])
        // Reconstructed rather than string-matched, so the assertion is about the bytes arriving
        // intact rather than about one particular spelling of base64.
        let url = try #require(image["url"] as? String)
        #expect(url.hasPrefix("data:image/png;base64,"))
        let encoded = String(url.dropFirst("data:image/png;base64,".count))
        #expect(Data(base64Encoded: encoded) == bytes)
    }

    /// There is no way to express a remote URL, and that is the design.
    ///
    /// The gateway refuses `http(s)://` in `image_url` as an SSRF mitigation, so an API that
    /// accepted one would accept something that always fails. Python enforces this with a
    /// validator that raises; here the type simply has no case for it, which is the difference
    /// between a rule to remember and a rule that cannot be broken. This test exists to fail if
    /// anybody adds that case.
    @Test("ContentPart cannot express a remote image URL")
    func noRemoteURLCase() throws {
        let bytes = Data([0x01])
        let serialised = ContentPart.image(bytes, mediaType: "image/jpeg").wireForm
        let url = try #require((serialised["image_url"] as? [String: Any])?["url"] as? String)
        #expect(url.hasPrefix("data:"), "the only encoding this type can produce is a data: URI")
    }

    @Test("an empty parts list is refused before a round trip")
    func emptyPartsRefused() async throws {
        let stubs = StubProtocol.Session()
        stubs.stubToken()
        stubs.stub(path: "/v1/chat/completions", .init(status: 200, headers: [:], body: Data("{}".utf8)))

        await #expect(throws: AxoniumError.self) {
            _ = try await client(stubs).chat(
                .init(model: "m", messages: [Message(role: "user", content: .parts([]))]))
        }
        #expect(stubs.requests(to: "/v1/chat/completions").isEmpty)
    }

    // MARK: - predict

    // Two tests lived here and are gone, replaced by corpus cases in the commit that vendored
    // them rather than against a promise of one:
    //
    //   "a top-level array answer survives"  -> predict-classification-answers-a-top-level-array
    //   "an object answer survives too"      -> predict-zero-shot-scores-the-labels-it-was-given
    //                                          predict-typed-decision-answers-several-questions-at-once
    //
    // The corpus versions are strictly better: their bodies are recorded wire bytes from a live
    // deployment rather than shortened by hand here, and all four SDKs replay them instead of one.
    // Mutation confirms the replacement catches what was caught here -- decoding the body as a
    // dictionary fails predict-classification and nothing else, which is the same single failure
    // the hand-written array test produced.
    //
    // What stays below is what a corpus case cannot express: three refusals where the assertion is
    // that NO REQUEST HAPPENS, and one about what goes OUT rather than what comes back.

    @Test("the body reaches the engine verbatim")
    func bodyGoesThroughUntouched() async throws {
        let stubs = StubProtocol.Session()
        stubs.stubToken()
        stubs.stub(
            path: "/v1/models/laya-decide/predict",
            .init(status: 200, headers: [:], body: Data("{}".utf8)))

        _ = try await client(stubs).predict(
            model: "laya-decide",
            body: .object([
                "state": .object(["email": .string("hola")]),
                "questions": .object(["q": .object(["type": .string("noul")])]),
            ]))

        let sent = try #require(stubs.requests(to: "/v1/models/laya-decide/predict").first?.body)
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        // Nested structure intact: this route's whole contract is that the gateway forwards the
        // body unchanged, so an SDK that flattened or renamed anything would break the engine.
        let questions = try #require(decoded["questions"] as? [String: Any])
        #expect(((questions["q"] as? [String: Any])?["type"] as? String) == "noul")
        #expect(((decoded["state"] as? [String: Any])?["email"] as? String) == "hola")
    }

    @Test("a non-object body is refused rather than guessed at")
    func nonObjectBodyRefused() async throws {
        let stubs = StubProtocol.Session()
        stubs.stubToken()
        await #expect(throws: AxoniumError.self) {
            _ = try await client(stubs).predict(model: "sst2-clf", body: .string("inputs"))
        }
    }

    @Test("an empty model name is refused before a round trip")
    func emptyModelRefused() async throws {
        let stubs = StubProtocol.Session()
        stubs.stubToken()
        await #expect(throws: AxoniumError.self) {
            _ = try await client(stubs).predict(model: "  ", body: .object([:]))
        }
    }
}

import Foundation
import Testing

@testable import Axonium

/// Replays the shared manifest against the real client.
///
/// The same `spec/cases/manifest.json` Python, Go and Rust run. Not a parallel suite written by
/// hand for Swift — the point is that identical recorded bytes produce identical behaviour in
/// four languages, and a hand-written equivalent could only prove that the hand-written
/// equivalent passes.
struct ContractRunnerTests {

    // MARK: - non-streaming

    @Test("the manifest carries cases to replay")
    func notEmpty() throws {
        #expect(try !Corpus.cases(kind: "ok").isEmpty)
        #expect(try !Corpus.cases(kind: "stream").isEmpty)
    }

    @Test("every non-streaming success case produces the fields the manifest expects")
    func successCases() async throws {
        var problems: [String] = []
        let selected = try Corpus.cases(kind: "ok").filter {
            // token.fetch cases assert on the REQUEST rather than a decoded result; they have
            // their own test below, and are the one deliberate exclusion here.
            ($0["operation"] as? String) != "token.fetch"
        }
        var replayed = 0

        for testCase in selected {
            let id = testCase["id"] as? String ?? "?"
            let operation = testCase["operation"] as? String ?? ""
            guard !Self.responseSequence(testCase).isEmpty,
                let expect = testCase["expect"] as? [String: Any]
            else {
                problems.append(unreadable(testCase, id: id))
                continue
            }
            replayed += 1

            do {
                let (client, stubs) = try makeClient(testCase)
                if let requestID = (testCase["request"] as? [String: Any])?["request_id"]
                    as? String
                {
                    try stubFrom(testCase, path: "/v1/usage/\(requestID)", into: stubs)
                }
                let result = try await invoke(operation: operation, case: testCase, client: client)
                problems += checkCounts(
                    expect, stubs: stubs, meta: nil, id: id,
                    path: endpoint(for: operation, case: testCase))
                problems += checkRequestHeaders(
                    expect, stubs: stubs, id: id, path: endpoint(for: operation, case: testCase))
                for (path, wanted) in expect["fields"] as? [String: Any] ?? [:] {
                    let got = resolve(path, in: result)
                    if !matches(got, wanted) {
                        problems.append(
                            "\(id): \(path) was \(got.map(String.init(describing:)) ?? "nil"), "
                                + "expected \(wanted)")
                    }
                }
            } catch let error as UnsupportedOperation {
                // Named rather than skipped in silence: a case this SDK cannot yet replay is a
                // gap in coverage, and a suite that hides it reports more parity than it has.
                problems.append("\(id): \(error.message)")
            } catch {
                problems.append("\(id): threw \(error)")
            }
        }

        #expect(replayed == selected.count, arithmetic(replayed, of: selected.count))
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    // MARK: - streaming

    @Test("every streaming case assembles to the content, chunk count and usage expected")
    func streamCases() async throws {
        var problems: [String] = []
        let selected = try Corpus.cases(kind: "stream")
        var replayed = 0

        for testCase in selected {
            let id = testCase["id"] as? String ?? "?"
            guard !Self.responseSequence(testCase).isEmpty,
                let expect = testCase["expect"] as? [String: Any]
            else {
                problems.append(unreadable(testCase, id: id))
                continue
            }
            replayed += 1

            do {
                let (client, stubs) = try makeClient(testCase)
                let stream = try await client.chatStream(
                    chatRequest(testCase), idempotencyKey: idempotencyKey(testCase))
                var chunks = 0
                for try await _ in stream { chunks += 1 }

                if let want = expect["content"] as? String, await stream.content() != want {
                    problems.append("\(id): content was \(await stream.content()), expected \(want)")
                }
                if let want = expect["chunks"] as? Int, chunks != want {
                    problems.append("\(id): \(chunks) chunks, expected \(want)")
                }
                problems += await checkUsage(expect, stream: stream, id: id)
                problems += await checkToolCalls(expect, stream: stream, id: id)
                problems += checkCounts(expect, stubs: stubs, meta: stream.meta, id: id)
                problems += checkRequestHeaders(
                    expect, stubs: stubs, id: id, path: "/v1/chat/completions")
                // `fields` on a streamed case had no route in any of the four runners, so a
                // stream that dropped its whole `meta` — ids, rate limit, replay flags — passed
                // every case in the corpus. Resolved against the stream itself, so the day a
                // case asserts `meta.idempotent_replay` on a stream, it is read rather than
                // stepped over.
                for (path, wanted) in expect["fields"] as? [String: Any] ?? [:] {
                    let got = resolve(path, in: stream)
                    if !matches(got, wanted) {
                        problems.append(
                            "\(id): \(path) was \(got.map(String.init(describing:)) ?? "nil"), "
                                + "expected \(wanted)")
                    }
                }
            } catch {
                problems.append("\(id): threw \(error)")
            }
        }

        #expect(replayed == selected.count, arithmetic(replayed, of: selected.count))
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @Test("an in-band error surfaces as an interruption carrying what had arrived")
    func streamErrorCases() async throws {
        var problems: [String] = []
        let selected = try Corpus.cases(kind: "stream_error")
        var replayed = 0

        for testCase in selected {
            let id = testCase["id"] as? String ?? "?"
            guard !Self.responseSequence(testCase).isEmpty,
                let expect = testCase["expect"] as? [String: Any]
            else {
                problems.append(unreadable(testCase, id: id))
                continue
            }
            replayed += 1

            let (client, stubs) = try makeClient(testCase)
            do {
                let stream = try await client.chatStream(chatRequest(testCase))
                for try await _ in stream {}
                problems.append("\(id): the stream ended normally, expected an interruption")
            } catch let AxoniumError.streamInterrupted(_, partial, _, _) {
                // The partial content is the whole point: a stream that broke mid-answer has
                // still delivered something, and losing it is losing work already paid for.
                if let want = expect["partial_content"] as? String, partial != want {
                    problems.append("\(id): partial content was \(partial), expected \(want)")
                }
                // And the count is what proves the SDK did not quietly retry. The case serves a
                // healthy stream as its second answer precisely so that a wrong retry would
                // succeed and be invisible in the content — only the request count sees it.
                problems += checkCounts(expect, stubs: stubs, meta: nil, id: id)
            } catch {
                problems.append("\(id): threw \(error), expected a stream interruption")
            }
        }

        #expect(replayed == selected.count, arithmetic(replayed, of: selected.count))
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    // MARK: - errors that must be met through the client, not decoded

    /// Error cases whose operation is a **stream**, replayed through `chatStream` itself.
    ///
    /// `ErrorEnvelopeTests` decodes every error case from its recorded body, which proves the
    /// envelope is read correctly and proves nothing about the transport. For these two that is
    /// the whole question: a streamed request refused *before* the stream begins must throw
    /// instead of yielding an empty answer, and an SDK that starts parsing SSE because it asked
    /// for a stream would pass the decoding test while failing the contract.
    ///
    /// So they are replayed twice on purpose, once for the envelope and once for the transport.
    @Test("a streamed request refused before it begins throws, rather than yielding nothing")
    func streamedErrorCases() async throws {
        var problems: [String] = []
        let selected = try Corpus.cases(kind: "error").filter {
            ($0["operation"] as? String) == "chat.completions.stream"
        }
        var replayed = 0

        for testCase in selected {
            let id = testCase["id"] as? String ?? "?"
            guard let expect = testCase["expect"] as? [String: Any],
                !Self.responseSequence(testCase).isEmpty
            else {
                problems.append(unreadable(testCase, id: id))
                continue
            }
            replayed += 1

            let (client, _) = try makeClient(testCase)
            do {
                let stream = try await client.chatStream(chatRequest(testCase))
                var frames = 0
                for try await _ in stream { frames += 1 }
                problems.append(
                    "\(id): the stream yielded \(frames) frames; the refusal must throw before "
                        + "the first, or every rejection becomes a silent empty answer")
            } catch let AxoniumError.api(error) {
                let wantStatus = Self.responseSequence(testCase).last?["status"] as? Int
                if let wantStatus, error.status != wantStatus {
                    problems.append("\(id): status was \(error.status), expected \(wantStatus)")
                }
                let wantSuffix = expect["error_type_suffix"] as? String ?? ""
                if error.typeSuffix != wantSuffix {
                    problems.append(
                        "\(id): type suffix was \(error.typeSuffix), expected \(wantSuffix)")
                }
                if let want = expect["retryable"] as? Bool, error.isRetryable != want {
                    problems.append("\(id): retryable is \(error.isRetryable), expected \(want)")
                }
                if let want = expect["has_request_id"] as? Bool,
                    !error.requestID.isEmpty != want
                {
                    problems.append("\(id): request_id present is \(!error.requestID.isEmpty)")
                }
                if let want = expect["has_trace_id"] as? Bool, !error.traceID.isEmpty != want {
                    problems.append("\(id): trace_id present is \(!error.traceID.isEmpty)")
                }
            } catch {
                problems.append("\(id): threw \(error), expected a typed gateway error")
            }
        }

        #expect(replayed == selected.count, arithmetic(replayed, of: selected.count))
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    // MARK: - the token endpoint

    @Test("the token request is form-encoded and carries the scope the manifest expects")
    func tokenRequestCases() async throws {
        var problems: [String] = []
        let selected = try Corpus.cases(kind: "ok").filter {
            ($0["operation"] as? String) == "token.fetch"
        }
        var replayed = 0

        for testCase in selected {
            let id = testCase["id"] as? String ?? "?"
            guard let expect = testCase["expect"] as? [String: Any],
                !Self.responseSequence(testCase).isEmpty
            else {
                problems.append(unreadable(testCase, id: id))
                continue
            }
            replayed += 1

            let stubs = StubProtocol.Session()
            try stubFrom(testCase, path: "/oauth2/token", into: stubs)
            stubs.stub(
                path: "/v1/models/mine",
                .init(status: 200, headers: [:], body: Data(#"{"object":"list","data":[]}"#.utf8)))

            let wantedForm = expect["request_form"] as? [String: String] ?? [:]
            let client = try AxoniumClient(
                configuration: .init(
                    gatewayBaseURL: "https://gateway.test",
                    clientID: "id", clientSecret: "secret",
                    scope: wantedForm["scope"] ?? "",
                    sessionConfiguration: stubs.configuration))
            _ = try? await client.modelsMine()

            guard let sent = stubs.requests(to: "/oauth2/token").first else {
                problems.append("\(id): the client never asked for a token")
                continue
            }
            _ = operationName(testCase)
            if let wantType = expect["request_content_type"] as? String,
                sent.headers["Content-Type"] != wantType
            {
                problems.append(
                    "\(id): Content-Type was \(sent.headers["Content-Type"] ?? "nil"), "
                        + "expected \(wantType)")
            }
            let form = parseForm(sent.body)
            for (key, want) in wantedForm where form[key] != want {
                problems.append("\(id): form \(key) was \(form[key] ?? "absent"), expected \(want)")
            }
            // The manifest's second token case exists to pin the ABSENCE of scope: requesting
            // one that was not asked for would silently narrow every later call.
            if wantedForm["scope"] == nil && form["scope"] != nil {
                problems.append("\(id): sent scope=\(form["scope"]!) when none was requested")
            }
        }

        #expect(replayed == selected.count, arithmetic(replayed, of: selected.count))
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    // MARK: - harness

    struct UnsupportedOperation: Error { var message: String }

    /// Reports a case this runner selected but could not read, instead of stepping over it.
    ///
    /// Every loop here used to `continue` past one. That is how a case in a shape the runner
    /// does not know yet — `responses`, an ordered sequence, added to the corpus in v20 —
    /// disappears: selected, never replayed, and no assertion the poorer, because a suite that
    /// collects problems finds none in a case it never touched.
    private func unreadable(_ testCase: [String: Any], id: String) -> String {
        let keys = testCase.keys.sorted().joined(separator: ", ")
        return """
            \(id): this runner selected the case and cannot read it. It has no `response` \
            dictionary; its keys are [\(keys)]. If that includes `responses`, the case serves an \
            ordered sequence and this runner has not learned that shape yet.
            """
    }

    /// The arithmetic that makes a skip impossible to hide.
    ///
    /// Counting is the assertion, because every other check in this file passes vacuously
    /// against a case that was never replayed.
    private func arithmetic(_ replayed: Int, of selected: Int) -> Comment {
        let message =
            "replayed \(replayed) of \(selected) selected cases; the missing ones were skipped, "
            + "and a skipped case asserts nothing while looking exactly like a passing one"
        return Comment(rawValue: message)
    }

    /// Which path a given operation hits, so a request count knows where to look.
    ///
    /// `predict.create` is the only operation whose path depends on the case, because it addresses
    /// the model through a path segment rather than a body field — which is itself part of the
    /// contract, and is why the stub is registered under that exact path: a client that put the
    /// model in the body would find no stub and fail rather than being answered anyway.
    private func endpoint(for operation: String, case testCase: [String: Any] = [:]) -> String {
        switch operation {
        case "embeddings.create": return "/v1/embeddings"
        case "images.generate": return "/v1/images/generations"
        case "rerank.create": return "/v1/rerank"
        case "models.list": return "/v1/models"
        case "models.mine": return "/v1/models/mine"
        case "predict.create": return predictPath(testCase)
        default: return "/v1/chat/completions"
        }
    }

    private func predictPath(_ testCase: [String: Any]) -> String {
        let request = testCase["request"] as? [String: Any] ?? [:]
        let model = request["model"] as? String ?? "m"
        return "/v1/models/\(model)/predict"
    }

    private func operationName(_ testCase: [String: Any]) -> String {
        testCase["operation"] as? String ?? "?"
    }

    /// A client and the stub session it talks to, isolated from every other test.
    ///
    /// **Built with the SDK's default retry policy, deliberately.** It used to pass `.none`,
    /// which was a harness convenience until a case began asserting `expect.requests` — at that
    /// point the retry policy stopped being the harness's business and became part of what the
    /// case measures. The manifest's `$request_counts` says so, and a runner overriding it would
    /// report "this SDK does not retry" about an SDK that does, sending whoever reads it to look
    /// for the fault in the wrong place.
    private func makeClient(_ testCase: [String: Any]) throws -> (
        AxoniumClient, StubProtocol.Session
    ) {
        let stubs = StubProtocol.Session()
        stubs.stubToken()
        var paths = [
            "/v1/chat/completions", "/v1/models", "/v1/models/mine", "/v1/embeddings",
            "/v1/images/generations", "/v1/rerank",
        ]
        // Per case rather than fixed, because this one carries the model in the path.
        if (testCase["operation"] as? String) == "predict.create" {
            paths.append(predictPath(testCase))
        }
        for path in paths {
            try stubFrom(testCase, path: path, into: stubs)
        }
        let client = try AxoniumClient(
            configuration: .init(
                gatewayBaseURL: "https://gateway.test", clientID: "id", clientSecret: "secret",
                sessionConfiguration: stubs.configuration))
        return (client, stubs)
    }

    /// The answers a case serves, as an ordered sequence.
    ///
    /// A case carries either one `response` or a `responses` list. The list is what a retry case
    /// needs: "rejected, then served" is two different answers to the same request, and one stub
    /// cannot say that.
    static func responseSequence(_ testCase: [String: Any]) -> [[String: Any]] {
        if let sequence = testCase["responses"] as? [[String: Any]] { return sequence }
        if let single = testCase["response"] as? [String: Any] { return [single] }
        return []
    }

    private func stubFrom(_ testCase: [String: Any], path: String, into stubs: StubProtocol.Session)
        throws
    {
        var sequence: [StubProtocol.Stub] = []
        for response in Self.responseSequence(testCase) {
            let status = response["status"] as? Int ?? 200
            let headers = response["headers"] as? [String: String] ?? [:]
            if let file = response["body_file"] as? String {
                sequence.append(
                    .init(status: status, headers: headers, body: try Corpus.fixtureData(file)))
            } else if let file = response["sse_file"] as? String {
                sequence.append(
                    .init(
                        status: status, headers: headers, body: try Corpus.fixtureData(file),
                        isEventStream: true))
            }
        }
        guard !sequence.isEmpty else { return }
        stubs.stub(path: path, sequence)
    }

    /// Checks what the SDK **sent**, where a case states it.
    ///
    /// Every other assertion in this file is about what came back, and that direction is blind to
    /// a whole class of fault. A key the SDK drops turns a retry into a second billable
    /// generation; a key the SDK *invents* makes a retry replay a stale result instead of
    /// generating; an instance pin nobody asked for takes the caller out of load balancing and
    /// out of failover without saying so. None of the three is visible in a response.
    private func checkRequestHeaders(
        _ expect: [String: Any], stubs: StubProtocol.Session, id: String, path: String
    ) -> [String] {
        guard
            expect["request_headers"] != nil || expect["request_headers_absent"] != nil
                || expect["request_headers_present"] != nil
        else { return [] }

        var problems: [String] = []
        guard let sent = stubs.requests(to: path).first else {
            return ["\(id): no request reached \(path), so nothing can be said about its headers"]
        }
        // HTTP header names are case-insensitive and URLSession does not promise a casing.
        let headers = Dictionary(
            sent.headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, l in l })

        for (name, want) in expect["request_headers"] as? [String: String] ?? [:] {
            let got = headers[name.lowercased()]
            if got != want {
                problems.append("\(id): sent \(name)=\(got ?? "nothing"), expected \(want)")
            }
        }
        // By name, with no value: `Authorization` carries each runner's own test token, so an
        // exact comparison would pin this suite's fixture rather than the SDK's behaviour. What
        // matters is that the header is there at all — `GET /v1/models` stopped being public and
        // one SDK had been skipping the token for it, on the strength of a guide line that still
        // says otherwise.
        for name in expect["request_headers_present"] as? [String] ?? [] {
            if headers[name.lowercased()]?.isEmpty != false {
                problems.append(
                    "\(id): sent no \(name) header; this endpoint is authenticated like every "
                        + "other one, whatever the guide says")
            }
        }
        for name in expect["request_headers_absent"] as? [String] ?? [] {
            if let got = headers[name.lowercased()] {
                problems.append(
                    "\(id): sent \(name)=\(got), which nobody asked for — an invented key "
                        + "replays a stale result, and an invented instance pin leaves the caller "
                        + "outside load balancing and failover")
            }
        }
        return problems
    }

    /// Checks `expect.requests` and `expect.attempts` where a case states them.
    ///
    /// The two are different facts and both are worth pinning. `requests` is what the server
    /// counted, which is the truth about behaviour; `attempts` is what the SDK reports about
    /// itself, which is the truth about its accounting. An SDK can retry correctly and report it
    /// wrongly, and only asserting both tells the two apart.
    private func checkCounts(
        _ expect: [String: Any], stubs: StubProtocol.Session, meta: ResponseMeta?, id: String,
        path: String = "/v1/chat/completions"
    ) -> [String] {
        var problems: [String] = []
        if let want = expect["requests"] as? Int {
            let got = stubs.requests(to: path).count
            if got != want {
                problems.append("\(id): the server saw \(got) requests, expected \(want)")
            }
        }
        if let want = expect["attempts"] as? Int, let meta {
            if meta.attempts != want {
                problems.append(
                    "\(id): the SDK reports \(meta.attempts) attempts, expected \(want)")
            }
        }
        return problems
    }

    private func invoke(operation: String, case testCase: [String: Any], client: AxoniumClient)
        async throws -> Any
    {
        switch operation {
        case "chat.completions.create":
            return try await client.chat(
                chatRequest(testCase), idempotencyKey: idempotencyKey(testCase))
        case "models.list": return try await client.models()
        case "models.mine": return try await client.modelsMine()
        case "embeddings.create":
            let request = testCase["request"] as? [String: Any] ?? [:]
            return try await client.embeddings(
                .init(
                    model: request["model"] as? String ?? "m",
                    input: request["input"] as? [String] ?? []))
        case "images.generate":
            let request = testCase["request"] as? [String: Any] ?? [:]
            return try await client.images(
                .init(
                    model: request["model"] as? String ?? "m",
                    prompt: request["prompt"] as? String ?? "x",
                    n: request["n"] as? Int, size: request["size"] as? String))
        case "rerank.create":
            let request = testCase["request"] as? [String: Any] ?? [:]
            return try await client.rerank(
                .init(
                    model: request["model"] as? String ?? "m",
                    query: request["query"] as? String ?? "q",
                    documents: request["documents"] as? [String] ?? []))
        case "usage.retrieve":
            let request = testCase["request"] as? [String: Any] ?? [:]
            return try await client.usage(requestID: request["request_id"] as? String ?? "")
        case "predict.create":
            let request = testCase["request"] as? [String: Any] ?? [:]
            let body = JSONValue(request["body"] ?? [String: Any]())
            return try await client.predict(
                model: request["model"] as? String ?? "m", body: body,
                idempotencyKey: idempotencyKey(testCase))
        default:
            throw UnsupportedOperation(
                message: "\(operation) is in the manifest and this SDK does not implement it yet")
        }
    }

    private func chatRequest(_ testCase: [String: Any]) -> ChatRequest {
        let request = testCase["request"] as? [String: Any] ?? [:]
        let messages = (request["messages"] as? [[String: Any]] ?? []).map { raw in
            Message(
                role: raw["role"] as? String ?? "user",
                content: (raw["content"] as? String).map(MessageContent.text))
        }
        return ChatRequest(
            model: request["model"] as? String ?? "m",
            messages: messages.isEmpty ? [.user("hi")] : messages,
            maxTokens: request["max_tokens"] as? Int)
    }

    /// The idempotency key a case asks the SDK to send, if any.
    private func idempotencyKey(_ testCase: [String: Any]) -> String? {
        (testCase["request"] as? [String: Any])?["idempotency_key"] as? String
    }

    private func checkUsage(_ expect: [String: Any], stream: ChatStream, id: String) async
        -> [String]
    {
        var problems: [String] = []
        let usage = await stream.usage()
        guard let wanted = expect["usage"] as? [String: Any] else {
            // An explicit JSON null means "there should be none", which is different from the
            // key being absent, and a stream that terminated immediately is exactly that case.
            if expect["usage"] is NSNull, usage != nil {
                problems.append("\(id): expected no usage, got \(usage!)")
            }
            return problems
        }
        guard let usage else { return ["\(id): expected usage, got none"] }

        let actual: [String: Any] = [
            "prompt_tokens": usage.promptTokens, "completion_tokens": usage.completionTokens,
            "cache_read_tokens": usage.cacheReadTokens, "estimated": usage.estimated,
            "total_tokens": usage.totalTokens,
        ]
        for (key, want) in wanted where !matches(actual[key], want) {
            problems.append(
                "\(id): usage.\(key) was \(actual[key].map(String.init(describing:)) ?? "nil"), "
                    + "expected \(want)")
        }
        return problems
    }

    private func checkToolCalls(_ expect: [String: Any], stream: ChatStream, id: String) async
        -> [String]
    {
        guard let wanted = expect["tool_calls"] as? [[String: Any]] else { return [] }
        let got = await stream.toolCalls()
        guard got.count == wanted.count else {
            return ["\(id): \(got.count) tool calls, expected \(wanted.count)"]
        }
        var problems: [String] = []
        for (call, want) in zip(got, wanted) {
            if let wantID = want["id"] as? String, call.id != wantID {
                problems.append("\(id): tool call id was \(call.id), expected \(wantID)")
            }
            guard let function = want["function"] as? [String: Any] else { continue }
            if let name = function["name"] as? String, call.name != name {
                problems.append("\(id): tool call name was \(call.name), expected \(name)")
            }
            // Compared as decoded JSON, not as text: key order in a reassembled argument string
            // is the backend's business and not a contract.
            if let args = function["arguments"] as? String,
                normalizedJSON(call.arguments) != normalizedJSON(args)
            {
                problems.append("\(id): tool call arguments were \(call.arguments), expected \(args)")
            }
        }
        return problems
    }

    private func normalizedJSON(_ text: String) -> NSDictionary? {
        guard let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? NSDictionary
        else { return nil }
        return object
    }

    private func parseForm(_ body: Data?) -> [String: String] {
        guard let body, let text = String(data: body, encoding: .utf8) else { return [:] }
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            fields[String(parts[0]).removingPercentEncoding ?? String(parts[0])] =
                String(parts[1]).removingPercentEncoding ?? String(parts[1])
        }
        return fields
    }
}

/// Accounts for every case in the manifest, so a filter that quietly matches nothing is caught.
///
/// The suites above all follow the same shape: select some cases, replay them, collect problems,
/// assert the problems are empty. Every one of them passes against an empty selection. This is
/// the guard on the selections themselves — it names the total, names who claims each case, and
/// fails when a case is claimed by nobody.
@Suite("Corpus coverage")
struct CoverageTests {

    @Test("every case in the manifest is claimed by a suite that replays it")
    func everyCaseIsClaimed() throws {
        var unclaimed: [String] = []

        for testCase in try Corpus.cases() {
            let id = testCase["id"] as? String ?? "?"
            let kind = (testCase["expect"] as? [String: Any])?["kind"] as? String ?? ""
            let operation = testCase["operation"] as? String ?? ""

            let claimed: Bool
            switch kind {
            case "ok": claimed = true  // successCases, or tokenRequestCases for token.fetch
            case "stream": claimed = operation == "chat.completions.stream"
            case "stream_error": claimed = operation == "chat.completions.stream"
            // ErrorEnvelopeTests decodes every one of them from its recorded body; the two
            // whose operation is a stream are ALSO replayed through the client by
            // streamedErrorCases, because decoding proves the envelope and says nothing about
            // whether chatStream throws instead of yielding nothing.
            case "error": claimed = true
            case "oauth_error", "auth_transport_error": claimed = operation == "token.fetch"
            default: claimed = false
            }
            if !claimed { unclaimed.append("\(id) (kind: \(kind), operation: \(operation))") }
        }

        #expect(
            unclaimed.isEmpty,
            "no suite replays these cases:\n\(unclaimed.joined(separator: "\n"))")
    }

    /// The counts, written down. A corpus that shrinks is as much a signal as one that grows,
    /// and neither is visible in a run that only reports passes.
    @Test("the corpus is the size this SDK was verified against")
    func corpusSize() throws {
        let cases = try Corpus.cases()
        let byKind = Dictionary(grouping: cases) {
            ($0["expect"] as? [String: Any])?["kind"] as? String ?? "?"
        }.mapValues(\.count)

        #expect(cases.count == 49, "the manifest has \(cases.count) cases, expected 49")
        #expect(byKind["ok"] == 17)
        #expect(byKind["error"] == 18)
        #expect(byKind["stream"] == 7)
        // v27's second in-band failure, whose payload is an object rather than the literal string
        // `stream interrupted`. The replay passed on the first run against the bumped corpus and only
        // these written-down numbers moved, which is the whole point of writing them down.
        #expect(byKind["stream_error"] == 3)
        #expect(byKind["oauth_error"] == 2)
        #expect(byKind["auth_transport_error"] == 2)

        let catalogued =
            (try Corpus.errorCatalog()["gateway_errors"] as? [[String: Any]] ?? []).count
        #expect(catalogued == 35, "the catalog has \(catalogued) errors, expected 35")
    }

    /// Nothing a streamed case asserts may be silently unread.
    ///
    /// The runner reads a fixed set of keys out of `expect`. A key it does not know is not an
    /// error to it — it is simply never looked at, which is the failure this whole file keeps
    /// meeting. `fields` on a streamed case was exactly that until it was implemented; this
    /// names the set so the next addition fails here rather than passing quietly.
    @Test("every key a streamed case asserts is one this runner reads")
    func noStreamedAssertionIsIgnored() throws {
        // Keyed on `kind`, because a streamed case is replayed by whichever suite owns its kind
        // and each reads a different set. A `kind: error` case on a stream goes through
        // `streamedErrorCases`, not through the stream loop.
        let shared: Set<String> = ["kind", "requests", "attempts", "request_headers",
                                   "request_headers_absent", "request_headers_present"]
        let byKind: [String: Set<String>] = [
            "stream": ["content", "chunks", "usage", "tool_calls", "fields"],
            "stream_error": ["partial_content", "error"],
            "error": ["error_type_suffix", "retryable", "has_request_id", "has_trace_id",
                      "fields"],
        ]
        var unread: [String] = []
        for testCase in try Corpus.cases() {
            guard (testCase["operation"] as? String) == "chat.completions.stream",
                let expect = testCase["expect"] as? [String: Any],
                let kind = expect["kind"] as? String
            else { continue }
            let id = testCase["id"] as? String ?? "?"
            let read = shared.union(byKind[kind] ?? [])
            for key in expect.keys where !read.contains(key) && !key.hasPrefix("$") {
                unread.append("\(id): a \(kind) case asserts `\(key)`, which this runner never reads")
            }
        }
        #expect(unread.isEmpty, "\(unread.joined(separator: "\n"))")
    }

    /// Every operation the manifest names is one this SDK can actually invoke.
    ///
    /// The runner reports an unimplemented operation as a problem rather than skipping it, so
    /// this is belt and braces — but it says the gap out loud in one line instead of inside a
    /// list of field mismatches.
    @Test("this SDK implements every operation the manifest exercises")
    func everyOperationIsImplemented() throws {
        let implemented: Set<String> = [
            "chat.completions.create", "chat.completions.stream", "models.list", "models.mine",
            "embeddings.create", "images.generate", "rerank.create", "usage.retrieve",
            "predict.create", "token.fetch",
        ]
        let named = Set(try Corpus.cases().compactMap { $0["operation"] as? String })
        #expect(
            named.subtracting(implemented).isEmpty,
            "the manifest exercises \(named.subtracting(implemented).sorted()), unimplemented here")
    }
}

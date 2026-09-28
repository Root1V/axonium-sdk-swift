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
            guard let response = testCase["response"] as? [String: Any],
                let expect = testCase["expect"] as? [String: Any]
            else {
                problems.append(unreadable(testCase, id: id))
                continue
            }
            replayed += 1

            do {
                let (client, stubs) = try makeClient(response: response)
                if let requestID = (testCase["request"] as? [String: Any])?["request_id"]
                    as? String
                {
                    try stubFrom(response, path: "/v1/usage/\(requestID)", into: stubs)
                }
                let result = try await invoke(operation: operation, case: testCase, client: client)
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
            guard let response = testCase["response"] as? [String: Any],
                let expect = testCase["expect"] as? [String: Any]
            else {
                problems.append(unreadable(testCase, id: id))
                continue
            }
            replayed += 1

            do {
                let (client, _) = try makeClient(response: response)
                let stream = try await client.chatStream(chatRequest(testCase))
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
            guard let response = testCase["response"] as? [String: Any],
                let expect = testCase["expect"] as? [String: Any]
            else {
                problems.append(unreadable(testCase, id: id))
                continue
            }
            replayed += 1

            let (client, _) = try makeClient(response: response)
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
            } catch {
                problems.append("\(id): threw \(error), expected a stream interruption")
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
                let response = testCase["response"] as? [String: Any]
            else {
                problems.append(unreadable(testCase, id: id))
                continue
            }
            replayed += 1

            let stubs = StubProtocol.Session()
            try stubFrom(response, path: "/oauth2/token", into: stubs)
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

    private func operationName(_ testCase: [String: Any]) -> String {
        testCase["operation"] as? String ?? "?"
    }

    /// A client and the stub session it talks to, isolated from every other test.
    private func makeClient(response: [String: Any]) throws -> (AxoniumClient, StubProtocol.Session)
    {
        let stubs = StubProtocol.Session()
        stubs.stubToken()
        for path in [
            "/v1/chat/completions", "/v1/models", "/v1/models/mine", "/v1/embeddings",
            "/v1/images/generations", "/v1/rerank",
        ] {
            try stubFrom(response, path: path, into: stubs)
        }
        let client = try AxoniumClient(
            configuration: .init(
                gatewayBaseURL: "https://gateway.test", clientID: "id", clientSecret: "secret",
                retry: .none, sessionConfiguration: stubs.configuration))
        return (client, stubs)
    }

    private func stubFrom(_ response: [String: Any], path: String, into stubs: StubProtocol.Session)
        throws
    {
        let status = response["status"] as? Int ?? 200
        let headers = response["headers"] as? [String: String] ?? [:]
        if let file = response["body_file"] as? String {
            stubs.stub(
                path: path,
                .init(status: status, headers: headers, body: try Corpus.fixtureData(file)))
        } else if let file = response["sse_file"] as? String {
            stubs.stub(
                path: path,
                .init(
                    status: status, headers: headers, body: try Corpus.fixtureData(file),
                    isEventStream: true))
        }
    }

    private func invoke(operation: String, case testCase: [String: Any], client: AxoniumClient)
        async throws -> Any
    {
        switch operation {
        case "chat.completions.create": return try await client.chat(chatRequest(testCase))
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
        default:
            throw UnsupportedOperation(
                message: "\(operation) is in the manifest and this SDK does not implement it yet")
        }
    }

    private func chatRequest(_ testCase: [String: Any]) -> ChatRequest {
        let request = testCase["request"] as? [String: Any] ?? [:]
        let messages = (request["messages"] as? [[String: Any]] ?? []).map { raw in
            Message(
                role: raw["role"] as? String ?? "user", content: raw["content"] as? String)
        }
        return ChatRequest(
            model: request["model"] as? String ?? "m",
            messages: messages.isEmpty ? [.user("hi")] : messages,
            maxTokens: request["max_tokens"] as? Int)
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
            case "error": claimed = true  // ErrorEnvelopeTests replays all of them
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

        #expect(cases.count == 40, "the manifest has \(cases.count) cases, expected 40")
        #expect(byKind["ok"] == 14)
        #expect(byKind["error"] == 15)
        #expect(byKind["stream"] == 6)
        #expect(byKind["stream_error"] == 1)
        #expect(byKind["oauth_error"] == 2)
        #expect(byKind["auth_transport_error"] == 2)

        let catalogued =
            (try Corpus.errorCatalog()["gateway_errors"] as? [[String: Any]] ?? []).count
        #expect(catalogued == 32, "the catalog has \(catalogued) errors, expected 32")
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
            "token.fetch",
        ]
        let named = Set(try Corpus.cases().compactMap { $0["operation"] as? String })
        #expect(
            named.subtracting(implemented).isEmpty,
            "the manifest exercises \(named.subtracting(implemented).sorted()), unimplemented here")
    }
}

import Foundation
import Testing

@testable import Axonium

/// Replays every error case in the shared manifest against this SDK's envelope decoding.
///
/// These are the cases that need no HTTP: the bytes are in `spec/fixtures/`, the expectations are
/// in `spec/cases/manifest.json`, and what is under test is whether the same bytes produce the
/// same typed error here as in Python, Go and Rust. The transport-level cases follow once the
/// client exists; this is the half that can be true first.
@Suite("Error envelopes from the shared corpus")
struct ErrorEnvelopeTests {

    /// A suite that replays no cases proves nothing and passes.
    @Test("the manifest carries error cases to replay")
    func theManifestIsNotEmpty() throws {
        #expect(try !errorCases().isEmpty)
        #expect(try !oauthCases().isEmpty)
    }

    @Test("every gateway error case decodes to the type and retryability the manifest expects")
    func gatewayErrorCases() throws {
        var problems: [String] = []

        for testCase in try errorCases() {
            let id = testCase["id"] as? String ?? "?"
            guard
                let response = testCase["response"] as? [String: Any],
                let status = response["status"] as? Int,
                let bodyFile = response["body_file"] as? String,
                let expect = testCase["expect"] as? [String: Any]
            else {
                problems.append("\(id): the case is missing a response or an expectation")
                continue
            }

            let headers = response["headers"] as? [String: String] ?? [:]
            let body = try Corpus.fixtureJSON(bodyFile)
            let rateLimit = RateLimitSnapshot.fromHeaders(headers).withScope(from: body)
            let error = ProblemDetails.apiError(
                status: status,
                body: body,
                headers: headers,
                retryAfter: headers["Retry-After"].flatMap(Double.init),
                rateLimit: rateLimit.isEmpty ? nil : rateLimit
            )

            if let want = expect["error_type_suffix"] as? String, error.typeSuffix != want {
                problems.append("\(id): type suffix is \(error.typeSuffix), expected \(want)")
            }
            if let want = expect["retryable"] as? Bool, error.isRetryable != want {
                problems.append("\(id): retryable is \(error.isRetryable), expected \(want)")
            }
            // has_request_id / has_trace_id are what caught the bug the other three shipped: an
            // error whose body has no ids while the headers carry them. Both sources are read
            // above, so a case expecting `true` fails if either the body path or the header
            // fallback is dropped.
            if let want = expect["has_request_id"] as? Bool, !error.requestID.isEmpty != want {
                problems.append("\(id): request_id present is \(!error.requestID.isEmpty), expected \(want)")
            }
            if let want = expect["has_trace_id"] as? Bool, !error.traceID.isEmpty != want {
                problems.append("\(id): trace_id present is \(!error.traceID.isEmpty), expected \(want)")
            }
            for (path, wanted) in expect["fields"] as? [String: Any] ?? [:] {
                let got = field(path, of: error)
                if !matches(got, wanted) {
                    problems.append("\(id): \(path) is \(got.map(String.init(describing:)) ?? "nil"), expected \(wanted)")
                }
            }
        }

        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @Test("every token-endpoint case picks the envelope its shape calls for")
    func tokenEndpointCases() throws {
        var problems: [String] = []

        for testCase in try oauthCases() {
            let id = testCase["id"] as? String ?? "?"
            guard
                let response = testCase["response"] as? [String: Any],
                let status = response["status"] as? Int,
                let expect = testCase["expect"] as? [String: Any],
                let kind = expect["kind"] as? String
            else { continue }

            // A non-JSON body is the point of one of these cases, so decoding is allowed to fail.
            let body: [String: Any]? = (response["body_file"] as? String).flatMap {
                try? Corpus.fixtureJSON($0)
            }
            let headers = response["headers"] as? [String: String] ?? [:]
            let error = ProblemDetails.tokenError(status: status, body: body, headers: headers)

            switch (kind, error) {
            case ("oauth_error", .oauth(let oauth)):
                if let want = expect["oauth_code"] as? String, oauth.code != want {
                    problems.append("\(id): oauth code is \(oauth.code), expected \(want)")
                }
            case ("auth_transport_error", .authTransport):
                break
            case ("error", .api(let api)):
                if let want = expect["error_type_suffix"] as? String, api.typeSuffix != want {
                    problems.append("\(id): type suffix is \(api.typeSuffix), expected \(want)")
                }
                if let want = expect["retryable"] as? Bool, api.isRetryable != want {
                    problems.append("\(id): retryable is \(api.isRetryable), expected \(want)")
                }
            default:
                problems.append("\(id): expected \(kind), got \(error)")
            }
        }

        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    // MARK: - case selection

    private func errorCases() throws -> [[String: Any]] {
        // The two token 503s are `kind: error` and go through the gateway envelope like any
        // other, so they belong here rather than with the OAuth shapes.
        try Corpus.cases().filter { ($0["expect"] as? [String: Any])?["kind"] as? String == "error" }
    }

    private func oauthCases() throws -> [[String: Any]] {
        try Corpus.cases().filter {
            guard let kind = ($0["expect"] as? [String: Any])?["kind"] as? String else { return false }
            return ($0["operation"] as? String) == "token.fetch"
                && ["oauth_error", "auth_transport_error", "error"].contains(kind)
        }
    }

    /// Resolves a dotted field path against the decoded error, using this SDK's own accessors.
    private func field(_ path: String, of error: APIError) -> Any? {
        switch path {
        case "rate_limit.scope": return error.rateLimit?.scope
        case "rate_limit.remaining_requests": return error.rateLimit?.remainingRequests
        case "rate_limit.limit_requests": return error.rateLimit?.limitRequests
        case "retry_after": return error.retryAfter
        case "status": return error.status
        default: return nil
        }
    }

}

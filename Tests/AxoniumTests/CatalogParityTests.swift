import Foundation
import Testing

@testable import Axonium

/// The error catalog and this SDK's mapping have to agree, and a test has to say so.
///
/// Every language SDK carries this guard and each one earned it the hard way. Go refused a change
/// until two new token errors had mappings, and refused again until their retryability matched.
/// Rust had no guard and silently shipped `upstream-unavailable` as not retryable. Python had none
/// either. This package starts with it rather than discovering it.
@Suite("Error catalog parity")
struct CatalogParityTests {

    /// Every assertion below is vacuously true against an empty list, which is exactly how a
    /// guard like this stops guarding without failing.
    @Test("the catalog is not empty")
    func theCatalogIsNotEmpty() throws {
        let entries = try gatewayErrors()
        #expect(!entries.isEmpty)
    }

    @Test("every catalogued error maps to a kind, with the catalogued retryability")
    func everyCataloguedErrorMaps() throws {
        var problems: [String] = []

        for entry in try gatewayErrors() {
            guard let suffix = entry["suffix"] as? String else { continue }

            for status in probeStatuses(entry) {
                // Built as a whole error rather than asking the kind directly, because one
                // catalogued entry's retryability is not a property of its kind:
                // predict-backend-rejected keeps the engine's status, and only the status can
                // answer. Asking `kind.isRetryable` would report false for a wrapped 429 and
                // this guard would agree with it.
                let error = ProblemDetails.apiError(
                    status: status,
                    body: [
                        "type": "https://gateway.example/errors/\(suffix)",
                        "title": suffix,
                        "detail": "something went wrong",
                    ],
                    headers: [:]
                )

                // A suffix this build does not know falls back to a status-keyed kind, which is
                // right for an unknown error and wrong for a catalogued one.
                if error.kind == .otherClientError || error.kind == .otherServerError
                    || error.kind == .unauthorized
                {
                    problems.append(
                        "\(suffix) is in spec/errors.json but this SDK maps no kind for it")
                    continue
                }

                let want = wantRetryable(entry, status: status)
                if error.isRetryable != want {
                    problems.append(
                        "\(suffix) at \(status): retryable is \(error.isRetryable) here, "
                            + "\(want) in the catalog")
                }
            }
        }

        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    /// The other direction: a kind here that the catalog does not list is a suffix this SDK
    /// invented, and would send a caller catching it on a case that never arrives.
    @Test("no mapped suffix is absent from the catalog")
    func noInventedSuffixes() throws {
        let catalogued = Set(try gatewayErrors().compactMap { $0["suffix"] as? String })
        let claimed = try Self.suffixesThisSDKClaims()

        // Each one resolved through the public initialiser, so a suffix that stops resolving
        // shows up here rather than looking absent.
        let mapped = claimed.filter { ErrorKind(suffix: $0, status: 400) != .otherClientError }

        let invented = Set(mapped).subtracting(catalogued)
        #expect(
            invented.isEmpty,
            "this SDK maps \(invented.sorted()) but spec/errors.json does not list them")
    }

    /// A guard on the guard above: the claimed suffixes must come from the code.
    ///
    /// If that list were maintained beside the initialiser rather than read out of it, the same
    /// hand would edit both — and the one thing it exists to catch, a suffix this SDK invented,
    /// is precisely what that hand would forget to declare.
    @Test("the claimed suffixes are read from the initialiser, and there are some")
    func claimedSuffixesComeFromTheSource() throws {
        let claimed = try Self.suffixesThisSDKClaims()
        // A pattern that matches nothing returns an empty list, and every check above passes
        // against one. If the initialiser is reformatted out of this shape, fail here rather
        // than quietly stop testing.
        #expect(claimed.count > 25, "read only \(claimed.count) suffixes from ErrorKind.swift")
        #expect(claimed.contains("backend-unavailable"))
        #expect(claimed.contains("capacity-exhausted"))
    }

    /// An unknown suffix must fall back by status rather than failing: the catalog grows, and an
    /// SDK that hard-failed on an unfamiliar code would break the day the gateway adds one.
    @Test("an unknown suffix falls back by status")
    func unknownSuffixFallsBack() {
        #expect(ErrorKind(suffix: "a-type-from-next-year", status: 400) == .otherClientError)
        #expect(ErrorKind(suffix: "a-type-from-next-year", status: 401) == .unauthorized)
        #expect(ErrorKind(suffix: "a-type-from-next-year", status: 503) == .otherServerError)
        #expect(ErrorKind(suffix: "", status: 422) == .otherClientError)
    }

    // MARK: - catalog reading

    private func gatewayErrors() throws -> [[String: Any]] {
        try Corpus.errorCatalog()["gateway_errors"] as? [[String: Any]] ?? []
    }

    /// The statuses an entry should be exercised at.
    ///
    /// Almost every entry fixes one. `predict-backend-rejected` does not -- it keeps whatever the
    /// engine returned, so the guide's row reads `4xx` -- and carries `probe_statuses` instead.
    /// A guard reading `status` alone would crash on that string, or worse, coerce it to zero.
    private func probeStatuses(_ entry: [String: Any]) -> [Int] {
        if let listed = entry["probe_statuses"] as? [Int], !listed.isEmpty { return listed }
        if let status = entry["status"] as? Int { return [status] }
        return []
    }

    /// What the catalog says retrying this entry at this status should do.
    private func wantRetryable(_ entry: [String: Any], status: Int) -> Bool {
        if let declared = entry["retryable"] as? Bool { return declared }
        let statuses = entry["retryable_statuses"] as? [Int] ?? []
        return statuses.contains(status)
    }

    /// The suffixes ``ErrorKind/init(suffix:status:)`` claims to resolve, read out of its source.
    ///
    /// **Derived, not written down.** This used to be a hand-maintained array, with a comment
    /// explaining that Swift has no reflection over a `switch` — true, and not a good enough
    /// reason. A list kept beside the code it describes is edited by the same hand that edits
    /// the code, so the one thing it guards against is the one thing that hand forgets.
    ///
    /// Measured rather than argued: adding `case "inventado-por-mi"` to the initialiser and not
    /// to the array left the whole suite green. The test meant to catch an invented suffix was
    /// the test that passed.
    ///
    /// A sibling SDK hit the same shape the same day — a `suffix -> kind` table in its own
    /// runner covering only what the corpus already exercised. Reading the source is blunt, and
    /// it is the only version of this that cannot drift.
    static func suffixesThisSDKClaims() throws -> [String] {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let source = try String(
            contentsOf: url.appendingPathComponent("Sources/Axonium/ErrorKind.swift"),
            encoding: .utf8)

        // `        case "some-suffix": self = .someKind` — anchored on the leading indentation
        // so a backticked suffix in a doc comment cannot be mistaken for a mapping.
        let pattern = try NSRegularExpression(
            pattern: "^        case \"([a-z0-9-]+)\": self = \\.",
            options: [.anchorsMatchLines])
        let range = NSRange(source.startIndex..., in: source)
        return pattern.matches(in: source, range: range).compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        }
    }
}

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
                let kind = ErrorKind(suffix: suffix, status: status)

                // A suffix this build does not know falls back to a status-keyed kind, which is
                // right for an unknown error and wrong for a catalogued one.
                if kind == .otherClientError || kind == .otherServerError || kind == .unauthorized {
                    problems.append(
                        "\(suffix) is in spec/errors.json but this SDK maps no kind for it")
                    continue
                }

                let want = wantRetryable(entry, status: status)
                if kind.isRetryable != want {
                    problems.append(
                        "\(suffix) at \(status): retryable is \(kind.isRetryable) here, "
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

        // Resolved through the public initialiser rather than a hand-written list, so a suffix
        // that stops resolving is caught here rather than looking absent.
        var mapped: [String] = []
        for suffix in Self.suffixesThisSDKClaims {
            let kind = ErrorKind(suffix: suffix, status: 400)
            if kind != .otherClientError { mapped.append(suffix) }
        }

        let invented = Set(mapped).subtracting(catalogued)
        #expect(
            invented.isEmpty,
            "this SDK maps \(invented.sorted()) but spec/errors.json does not list them")
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

    /// The suffixes ``ErrorKind/init(suffix:status:)`` claims to resolve.
    ///
    /// Written out rather than derived, because Swift has no reflection over a switch. It is the
    /// list the test above holds against the catalog, so a case added to the initialiser and
    /// forgotten here shows up as a catalogued suffix with no mapping in the other direction.
    static let suffixesThisSDKClaims = [
        "unknown-model", "modality-mismatch", "context-exceeded", "unknown-parameter",
        "unknown-instance", "invalid-idempotency-key", "inconsistent-model-group", "invalid-date",
        "invalid-range", "range-too-large", "missing-credentials", "invalid-token",
        "token-expired", "token-revoked", "unauthorized", "spend-cap-exceeded", "forbidden",
        "not-found", "idempotency-key-reuse", "idempotency-in-progress",
        "idempotency-response-not-retained", "validation-error", "rate-limit-exceeded-requests",
        "upstream-error", "model-not-loaded", "backend-unavailable", "rate-limiting-unavailable",
        "usage-store-unavailable", "upstream-unavailable", "not-configured",
    ]
}

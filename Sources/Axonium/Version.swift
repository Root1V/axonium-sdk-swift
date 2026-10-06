import Foundation

/// This package's version, as it appears to the gateway.
///
/// **Kept here alone, and held to the newest git tag by a test.** It used to be a literal beside
/// the header that sends it, and `0.1.1` shipped announcing itself as `0.1.0` — a release whose
/// own diagnostics point at the previous one. The Mundus team found it by reading the tag, which
/// is not where anybody should have to look.
///
/// Swift packages have no build-time equivalent of Cargo's `CARGO_PKG_VERSION`, so a constant is
/// unavoidable. What is avoidable is nobody checking it: a test fails when this falls **behind**
/// the newest tag in the repository, which turns forgetting it into a red run rather than a wrong
/// header in production.
///
/// Behind, not different. Between releases this is legitimately ahead of the newest tag — the
/// commit that raises it comes before the commit that tags it — and a check that is red by design
/// gets ignored, which is worse than no check.
public let axoniumVersion = "0.3.2"

/// The `User-Agent` this SDK sends.
let userAgent = "axonium-swift/\(axoniumVersion)"

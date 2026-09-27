// swift-tools-version: 6.0
import PackageDescription

// The corpus this package is tested against lives in the axonium-sdk monorepo and is pinned here
// as a git submodule (`Corpus/`), not copied. Copying would make a fourth place the contract is
// written down, and the whole reason this SDK can claim parity with Python, Go and Rust is that
// all four replay the same bytes.
//
// SwiftPM resolves a dependency's version from bare semver tags only. The monorepo's bare tags
// `v0.1.0`..`v0.6.0` belong to the legacy Python SDK, so `from: "0.1.0"` against that repository
// would resolve to a package with no Swift in it at all. That is what forced this into its own
// repository -- the resolver, not a preference.
let package = Package(
    name: "Axonium",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v1),
        .watchOS(.v10),
    ],
    products: [
        .library(name: "Axonium", targets: ["Axonium"])
    ],
    targets: [
        .target(
            name: "Axonium",
            // No external dependencies, by requirement: Foundation, Security and CryptoKit only.
            // An app shipping through App Store review inherits every transitive dependency's
            // privacy manifest and signature, so each one is a cost its consumer pays.
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AxoniumTests",
            dependencies: ["Axonium"],
            // The corpus is read at runtime from the submodule rather than bundled as a resource:
            // a resource copy is taken at build time and would silently go stale against a
            // submodule bump, which is the failure this package exists to avoid.
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

// swift-tools-version: 6.0
import PackageDescription

// The corpus this package is tested against lives in the axonium-sdk monorepo and is pinned here
// as a git submodule (`Corpus/`), not copied. Copying would make a fourth place the contract is
// written down, and the whole reason this SDK can claim parity with Python, Go and Rust is that
// all four replay the same bytes.
//
// This is its own repository by choice, and README.md gives the reasons. The first version of
// this comment claimed the resolver forced it; that was wrong. SwiftPM cannot consume a package
// living in a subdirectory, so a `swift/Package.swift` beside `go/` is genuinely impossible --
// but a manifest at the monorepo ROOT with `path: "swift/Sources/Axonium"` resolves and builds.
// Measured before believing it, and after having claimed the opposite.
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

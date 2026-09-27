import Foundation
import Testing

/// Reads the shared contract corpus out of the `Corpus/` submodule.
///
/// Read from disk at runtime rather than bundled as a SwiftPM resource. A resource is copied at
/// build time, and a copy of a submodule is exactly the thing this package exists not to have:
/// the corpus would go stale against a bump and every test would keep passing against yesterday's
/// contract. There is one copy, and it is the submodule.
enum Corpus {
    /// The repository root, found by walking up from this file.
    ///
    /// `#filePath` rather than `Bundle.module`, because the point is to reach a directory that is
    /// deliberately *not* in the bundle.
    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        // Tests/AxoniumTests/Corpus.swift -> Tests/AxoniumTests -> Tests -> repo root
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }()

    static let specDirectory = root.appendingPathComponent("Corpus/spec")

    /// Fails loudly rather than skipping when the submodule was never initialised.
    ///
    /// A test suite that quietly passes because it found no cases is the failure mode this whole
    /// corpus exists to prevent, and `git clone` without `--recurse-submodules` produces exactly
    /// that: an empty directory and a green run.
    static func requireSpecDirectory() throws -> URL {
        guard FileManager.default.fileExists(atPath: specDirectory.appendingPathComponent("errors.json").path)
        else {
            throw CorpusMissing(path: specDirectory.path)
        }
        return specDirectory
    }

    struct CorpusMissing: Error, CustomStringConvertible {
        let path: String
        var description: String {
            """
            The contract corpus is not there: \(path)

            It is a git submodule, so a plain clone leaves it empty. Run:
                git submodule update --init

            This is an error and not a skip on purpose. A suite that passes by finding no cases
            proves nothing, and would report green on a contract it never read.
            """
        }
    }

    static func json(_ relativePath: String) throws -> [String: Any] {
        let url = try requireSpecDirectory().appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CorpusMissing(path: url.path)
        }
        return object
    }

    static func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: try requireSpecDirectory().appendingPathComponent("fixtures/\(name)"))
    }

    static func fixtureJSON(_ name: String) throws -> [String: Any] {
        guard
            let object = try JSONSerialization.jsonObject(with: try fixtureData(name))
                as? [String: Any]
        else { throw CorpusMissing(path: name) }
        return object
    }

    /// `spec/errors.json`, the cross-language source of truth for the error taxonomy.
    static func errorCatalog() throws -> [String: Any] { try json("errors.json") }

    /// `spec/cases/manifest.json`, the index of contract cases every SDK replays.
    static func manifest() throws -> [String: Any] { try json("cases/manifest.json") }

    static func cases() throws -> [[String: Any]] {
        try manifest()["cases"] as? [[String: Any]] ?? []
    }
}

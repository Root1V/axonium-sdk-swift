import Foundation
import Testing

@testable import Axonium

/// The Swift examples on the documentation site have to name things this package actually has.
///
/// The site lives in the monorepo and shows every example in five languages. Four of those are
/// checkable from there, because those SDKs are in that repository; **Swift is not**, so until this
/// existed the Swift tabs were the one set of examples nothing verified. A renamed type would have
/// gone on being documented, correctly formatted and wrong, for as long as nobody tried it.
///
/// This is the mirror of `test_no_cited_name_has_stopped_existing` in the monorepo's Python suite,
/// and it reads the same pages — through the corpus submodule, which vendors the whole repository
/// and therefore `docs/` along with `spec/`. No copy, and no hand-kept list of Swift names over
/// there pretending to be checked.
@Suite("The site's Swift examples")
struct VendoredDocsTests {

    /// Names from the standard library, Foundation and Swift Concurrency. Everything else a Swift
    /// block mentions has to be declared in `Sources/`.
    ///
    /// Deliberately short. A long list here would be this guard being talked out of its own job one
    /// entry at a time, so a name belongs here only when it is demonstrably not ours.
    static let foreign: Set<String> = [
        "Any", "Data", "String", "Int", "Double", "Bool", "Error", "Task", "URL",
        "JSONSerialization", "URLProtocol", "URLSession", "URLSessionConfiguration",
        "Package", "Foundation",
    ]

    @Test("every type a Swift example names is declared in this package")
    func swiftExamplesNameRealTypes() throws {
        let pages = try documentationPages()
        #expect(!pages.isEmpty, "found no vendored pages, so this check would pass by seeing nothing")

        let declared = try declaredTypeNames()
        #expect(
            declared.contains("AxoniumClient"),
            Comment(
                rawValue:
                    "read \(declared.count) declarations and not the obvious one, so the parser is "
                    + "wrong and every name below would be reported as missing"))

        var unknown: [String: Set<String>] = [:]
        var blocks = 0

        for page in pages {
            let text = try String(contentsOf: page, encoding: .utf8)
            for block in swiftBlocks(in: text) {
                blocks += 1
                // A type the example DECLARES is not a claim about this package's surface --
                // `final class FakeGateway: URLProtocol` in a testing example is the reader's
                // type, not ours. Collected from the block rather than listed as an exception,
                // because the next example will declare a different one.
                let local = declaredTypeNames(in: block)
                for name in capitalisedIdentifiers(in: block)
                where !declared.contains(name) && !Self.foreign.contains(name)
                    && !local.contains(name)
                {
                    unknown[page.lastPathComponent, default: []].insert(name)
                }
            }
        }

        // A site that stopped showing Swift would make the loop above pass by iterating nothing,
        // which is the failure this whole suite exists to refuse elsewhere.
        #expect(blocks > 0, "no ```swift block on the whole site, so nothing was checked")

        let report = unknown
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value.sorted().joined(separator: ", "))" }
            .joined(separator: "\n")
        #expect(
            unknown.isEmpty,
            Comment(
                rawValue:
                    "the site's Swift examples name types this package does not declare:\n\(report)"
            ))
    }

    /// What a reader lands on has to have a route to the guide.
    ///
    /// Swift has no package registry, so its GitHub README *is* the landing page a SwiftPM user
    /// reaches. Measured 2026-10-06: it had no link to the documentation site, and neither did the
    /// four READMEs in the monorepo — five published front pages, zero routes to the guide. That
    /// repository has the mirror of this test for its own four.
    @Test("the README a SwiftPM user lands on links to the documentation")
    func readmeLinksToTheDocumentation() throws {
        let site = "https://root1v.github.io/axonium-sdk/"
        let readme = try String(
            contentsOf: repositoryRoot().appendingPathComponent("README.md"), encoding: .utf8)
        #expect(
            readme.contains(site),
            Comment(rawValue: "README.md does not link to \(site), which is the only guide there is"))
    }

    // MARK: - reading

    private func documentationPages() throws -> [URL] {
        let docs = repositoryRoot().appendingPathComponent("Corpus/docs")
        guard FileManager.default.fileExists(atPath: docs.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Every ```swift fence's contents.
    private func swiftBlocks(in text: String) -> [String] {
        var blocks: [String] = []
        var current: [Substring]?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current == nil {
                if line.hasPrefix("```swift") { current = [] }
            } else if line.hasPrefix("```") {
                blocks.append(current!.joined(separator: "\n"))
                current = nil
            } else {
                current?.append(line)
            }
        }
        return blocks
    }

    /// Capitalised words that are being used as a type, not as part of a string or a comment.
    ///
    /// Comments go first: half the explanation in these examples lives in them, and prose names
    /// things the code does not — "ONE PAIR", "Likewise" — which this would otherwise report as
    /// missing types.
    private func capitalisedIdentifiers(in block: String) -> Set<String> {
        var names: Set<String> = []
        for rawLine in block.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if let comment = line.range(of: "//") { line = String(line[line.startIndex..<comment.lowerBound]) }
            line = line.replacingOccurrences(
                of: "\"[^\"]*\"", with: " ", options: .regularExpression)
            for match in line.components(separatedBy: CharacterSet.alphanumerics.inverted)
            where match.first?.isUppercase == true && match.count > 1 {
                names.insert(match)
            }
        }
        return names
    }

    /// Types declared inside one example, which are the reader's and not this package's.
    private func declaredTypeNames(in block: String) -> Set<String> {
        var names: Set<String> = []
        for line in block.split(separator: "\n") {
            let words = line.split(separator: " ").map(String.init)
            for (index, word) in words.enumerated()
            where ["struct", "class", "enum", "protocol", "actor"].contains(word) {
                if let next = words[safe: index + 1] {
                    let name = next.prefix { $0.isLetter || $0.isNumber }
                    if let first = name.first, first.isUppercase { names.insert(String(name)) }
                }
            }
        }
        return names
    }

    private func declaredTypeNames() throws -> Set<String> {
        let sources = repositoryRoot().appendingPathComponent("Sources/Axonium")
        var names: Set<String> = []
        let pattern = try NSRegularExpression(
            pattern: #"\b(?:struct|class|enum|protocol|actor|typealias)\s+(\w+)"#)
        for file in try FileManager.default.contentsOfDirectory(
            at: sources, includingPropertiesForKeys: nil
        ) where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                if let r = Range(match.range(at: 1), in: text) { names.insert(String(text[r])) }
            }
        }
        return names
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AxoniumTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

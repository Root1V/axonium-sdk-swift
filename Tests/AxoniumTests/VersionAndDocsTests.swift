import Foundation
import Testing

@testable import Axonium

/// Two things nobody was checking, both found by somebody outside this repository.
@Suite("Version and doc references")
struct VersionAndDocsTests {

    /// The version constant must never be **behind** the newest tag.
    ///
    /// `0.1.1` shipped sending `axonium-swift/0.1.0`, so anyone diagnosing by version in a
    /// gateway's log counted its users as being on a release they were not on. The Mundus team
    /// found it by reading the tag, which is not where anybody should have to look.
    ///
    /// "Behind" and not "different", which is the rule the Go SDK in the sibling monorepo already
    /// uses. Between releases the constant is legitimately **ahead**: the commit that raises it
    /// comes before the commit that tags it, so demanding equality would fail every commit in
    /// between. A check that is red by design gets ignored, and an ignored check is worse than no
    /// check. Behind is the only direction that ships a lie.
    @Test("the version constant is not behind the newest git tag")
    func versionIsNotBehindTheNewestTag() throws {
        guard let newest = try newestTag() else {
            // Not a failure: a source checkout without git history is a legitimate way to build
            // this package. Printed, so a run that skipped says so rather than looking passed.
            print("skipped: no git tags reachable from here, so there is nothing to compare")
            return
        }
        #expect(
            !isOlder(axoniumVersion, than: newest),
            """
            axoniumVersion is \(axoniumVersion) and the newest tag is \(newest), so this build \
            announces itself as a release older than the one it is. Raise axoniumVersion in the \
            commit that prepares the release, before the tag is created.
            """)
    }

    /// Semver comparison, numeric rather than lexicographic.
    ///
    /// `"0.10.0" < "0.9.0"` when compared as strings, which would make this guard start lying the
    /// first time a minor version reached double digits — the same quiet wrongness it exists to
    /// catch.
    private func isOlder(_ version: String, than other: String) -> Bool {
        func parts(_ text: String) -> [Int] {
            text.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let mine = parts(version)
        let theirs = parts(other)
        for index in 0..<max(mine.count, theirs.count) {
            let left = index < mine.count ? mine[index] : 0
            let right = index < theirs.count ? theirs[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    /// The `User-Agent` is built from the constant rather than spelled out a second time.
    @Test("the User-Agent carries the version constant")
    func userAgentCarriesTheVersion() {
        #expect(userAgent == "axonium-swift/\(axoniumVersion)")
    }

    /// Every symbol reference in a doc comment must name something that exists.
    ///
    /// A reference to a typed `chat(_:as:)` layer shipped in `0.1.0` and `0.1.1` describing a
    /// method that was never written. The compiler has nothing to say about a name inside a
    /// comment, so it cost a reader the time to go looking — which is the whole damage an
    /// invented API name does.
    ///
    /// **Compares the argument labels, not just the name**, and the first version of this did
    /// not. It checked the base name before the first `(`, which would have passed the very
    /// reference that prompted it: `chat(_:as:idempotencyKey:instance:)` does not exist, but
    /// `chat` does, so the guard would have resolved it and reported nothing. Measured by
    /// reintroducing the reference and watching 23 tests stay green.
    ///
    /// A guard that gives assurance it has not earned is worse than the absence it replaces, so
    /// a function reference now has to match a declared signature: the name **and** the labels.
    @Test("every doc reference names something that exists")
    func docReferencesResolve() throws {
        let sources = try sourceFiles()
        #expect(!sources.isEmpty, "read no sources, so this check would pass by seeing nothing")

        let texts = try sources.map { try String(contentsOf: $0, encoding: .utf8) }
        let corpus = texts.joined(separator: "\n")
        let pattern = try NSRegularExpression(pattern: "``([^`]+)``")
        let signatures = declaredSignatures(in: corpus)
        #expect(
            signatures.contains("chat(_:idempotencyKey:instance:)"),
            Comment(
                rawValue:
                    "read \(signatures.count) signatures and not the obvious one, so the parser "
                    + "is wrong and every reference below would resolve against an empty set"))

        var dangling: [String] = []
        var checked = 0

        for text in texts {
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let r = Range(match.range(at: 1), in: text) else { continue }
                let reference = String(text[r])
                let member = reference.split(separator: "/").last.map(String.init) ?? reference
                let base = member.split(separator: "(").first.map(String.init) ?? member
                guard let first = base.first, first.isLetter else { continue }
                checked += 1

                // A reference carrying labels names one overload, so it resolves against the
                // declared signatures rather than against the bare name.
                if member.contains("(") {
                    if !signatures.contains(member) {
                        let near = signatures.filter { $0.hasPrefix("\(base)(") }.sorted()
                        dangling.append(
                            "``\(reference)`` -- no such signature."
                                + (near.isEmpty
                                    ? " Nothing named `\(base)` takes arguments."
                                    : " `\(base)` exists as: \(near.joined(separator: ", "))"))
                    }
                    continue
                }

                // `init` is spelled `init(`, never `func init(`. The first version of this list
                // forgot that and reported the package's own initialiser as dangling. Special-
                // cased rather than adding a bare `\(base)(` to the list, which would have let
                // every reference resolve against its own *call site* — and a checker that
                // resolves everything is the same as no checker.
                let declarations =
                    base == "init"
                    ? ["init("]
                    : [
                        "func \(base)(", "var \(base):", "var \(base) ", "let \(base) ",
                        "let \(base):", "case \(base)", "struct \(base)", "enum \(base)",
                        "class \(base)", "actor \(base)", "protocol \(base)", "typealias \(base)",
                    ]
                if !declarations.contains(where: corpus.contains) {
                    dangling.append("``\(reference)`` -- nothing named `\(base)` is declared")
                }
            }
        }

        #expect(checked > 10, "resolved only \(checked) references; the pattern stopped matching")
        #expect(dangling.isEmpty, "\(Set(dangling).sorted().joined(separator: "\n"))")
    }

    // MARK: -

    private func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }

    /// Every function and initialiser declared in the sources, in DocC's `name(label:label:)` form.
    ///
    /// Parsed with a regex rather than a real parser, which sets the limits honestly.
    ///
    /// **Comments are stripped first.** Without that, a declaration wrapped across lines swallows
    /// the `///` lines sitting inside it and yields signatures like `init(///:///:clientSecret:)`
    /// — and the reference to the real initialiser then reads as dangling. False alarms are how a
    /// check gets muted, and a muted check is the absence it was written to replace.
    ///
    /// **Enum cases count.** `case api(APIError)` is a declaration DocC refers to as `api(_:)`,
    /// and reading only `func` and `init` made every reference to this package's own error cases
    /// look invented.
    private func declaredSignatures(in source: String) -> Set<String> {
        // Line comments only: a `//` inside a string literal would be mangled, and no declaration
        // in this package has one.
        let code = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")

        guard
            let declaration = try? NSRegularExpression(
                // The parameter list allows one level of nesting, because a default value is
                // itself a call: `timeouts: Timeouts = Timeouts()`. Stopping at the first `)`
                // truncated the client's initialiser to five labels of eight, and the doc
                // reference to the real thing then read as dangling.
                pattern: #"(?:func\s+([A-Za-z_][A-Za-z0-9_]*)|case\s+([A-Za-z_][A-Za-z0-9_]*)|\binit)\s*(?:<[^>]*>)?\s*\(((?:[^()]|\([^()]*\))*)\)"#)
        else { return [] }

        var signatures: Set<String> = []
        let source = code
        let range = NSRange(source.startIndex..., in: source)
        for match in declaration.matches(in: source, range: range) {
            let name: String
            if let r = Range(match.range(at: 1), in: source) {
                name = String(source[r])
            } else if let r = Range(match.range(at: 2), in: source) {
                name = String(source[r])
            } else {
                name = "init"
            }
            guard let paramsRange = Range(match.range(at: 3), in: source) else { continue }
            let parameters = String(source[paramsRange])

            // `external internal: Type = default` -> the external label. An enum case's
            // associated values usually have no labels at all, which DocC writes as `_`.
            let labels = parameters
                .split(separator: ",")
                .map { parameter -> String in
                    guard parameter.contains(":") else { return "_" }
                    let head = parameter.split(separator: ":").first.map(String.init) ?? ""
                    let words = head.split(whereSeparator: \.isWhitespace).map(String.init)
                    return words.first ?? ""
                }
                .filter { !$0.isEmpty }

            signatures.insert("\(name)(\(labels.map { "\($0):" }.joined()))")
        }
        return signatures
    }

    private func sourceFiles() throws -> [URL] {
        let sources = repositoryRoot().appendingPathComponent("Sources/Axonium")
        return try FileManager.default.contentsOfDirectory(
            at: sources, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
    }

    /// The newest semver tag in this repository, by version order.
    private func newestTag() throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "tag", "--sort=-v:refname"]
        process.currentDirectoryURL = repositoryRoot()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }
}

import Foundation
import XCTest
@testable import WatchtowerCore

/// The scan nets of Decision 11 (#1886 Task 18). The compiler (`runModel` has
/// no default origin) and the runtime refusal (`CLIRunnerError
/// .modelCommandNeedsOrigin`) cover launches through `CLIRunner`; these cover
/// the launches that bypass it and, as an extra net, model argv literals.
final class DesktopModelLaunchSitesTests: XCTestCase {
    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Core
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // WatchtowerDesktop
        .appendingPathComponent("Sources")

    /// Every Swift file under `Sources/`, keyed by its path below it.
    private static func sourceFiles() throws -> [String: String] {
        let root = sources.standardizedFileURL.path + "/"
        var out: [String: String] = [:]
        let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let path = url.standardizedFileURL.path
            out[String(path.dropFirst(root.count))] = try String(contentsOf: url, encoding: .utf8)
        }
        return out
    }

    /// A file that finds the CLI binary and builds a `Process` of its own
    /// (directly or through `CodeCLIProcess.launch`).
    private static func launchesCLI(_ text: String) -> Bool {
        text.contains("findCLIPath")
            && (text.contains("Process()") || text.contains(".executableURL") || text.contains("CodeCLIProcess.launch"))
    }

    func testEveryProcessLaunchOfTheCLIIsListed() throws {
        let files = try Self.sourceFiles()
        XCTAssertFalse(files.isEmpty)
        for (path, text) in files where Self.launchesCLI(text) {
            guard let site = DesktopProcessLaunchSites.sites[path] else {
                XCTFail("\(path) launches the CLI outside CLIRunner: list it in DesktopProcessLaunchSites with "
                        + "whether it runs a model command, or launch through CLIRunner (runModel for a model command)")
                continue
            }
            XCTAssertFalse(site.reason.isEmpty, path)
            switch site.launch {
            case .noModel:
                break
            case .owner:
                XCTAssertTrue(text.contains("CLIOrigin.owner.environment"),
                              "\(path) runs a model command for the owner: build its environment with CLIOrigin.owner")
            case .background:
                XCTAssertTrue(text.contains("CLIOrigin.background.environment"),
                              "\(path) runs a model command in the background: it must set WATCHTOWER_AI_ORIGIN")
            }
        }
    }

    func testNoStaleEntries() throws {
        let files = try Self.sourceFiles()
        for path in DesktopProcessLaunchSites.sites.keys {
            guard let text = files[path] else {
                XCTFail("DesktopProcessLaunchSites lists \(path), which no longer exists")
                continue
            }
            XCTAssertTrue(Self.launchesCLI(text), "DesktopProcessLaunchSites lists \(path), which no longer launches the CLI")
        }
    }

    /// The round-1 string scan, kept as an extra net: a string-array literal
    /// that starts with a model command path — or is a proper prefix of one
    /// composed with `+` (`["workbench", "review"] + args`) — sits in a body
    /// (the enclosing `func`, `init` or computed `var`) that passes an origin:
    /// `runModel(` or `origin: .`. Listed `Process` launch sites that run a
    /// model are covered by `testEveryProcessLaunchOfTheCLIIsListed`; anything
    /// else is in `DesktopProcessLaunchSites.literalExemptions` with a reason.
    func testLiteralModelArgsUseRunModel() throws {
        let files = try Self.sourceFiles()
        let patterns = try Self.literalPatterns()
        let scopeStart = try NSRegularExpression(
            pattern: #"\b(?:func\s+([A-Za-z_][A-Za-z0-9_]*)|(init)\s*\(|var\s+([A-Za-z_][A-Za-z0-9_]*)\s*:[^=\n]*\{)"#)
        var found = 0
        var usedExemptions: Set<String> = []
        for (path, text) in files {
            let ns = text as NSString
            let whole = NSRange(location: 0, length: ns.length)
            let scopes = scopeStart.matches(in: text, range: whole)
            for pattern in patterns {
                for literal in pattern.matches(in: text, range: whole) {
                    found += 1
                    if DesktopProcessLaunchSites.literalExemptions[path] != nil {
                        usedExemptions.insert(path)
                        continue
                    }
                    if let site = DesktopProcessLaunchSites.sites[path], site.launch != .noModel { continue }
                    let before = scopes.last { $0.range.location <= literal.range.location }
                    let after = scopes.first { $0.range.location > literal.range.location }
                    let from = before?.range.location ?? 0
                    let body = ns.substring(with: NSRange(location: from, length: (after?.range.location ?? ns.length) - from))
                    let name = before.flatMap { scope in
                        (1...3).lazy.compactMap { i -> String? in
                            let r = scope.range(at: i)
                            return r.location == NSNotFound ? nil : ns.substring(with: r)
                        }.first
                    } ?? "-"
                    let key = "\(path)#\(name)"
                    if DesktopProcessLaunchSites.literalExemptions[key] != nil {
                        usedExemptions.insert(key)
                        continue
                    }
                    XCTAssertTrue(body.contains("runModel(") || body.contains("origin: ."),
                                  "\(key) builds a model command's argv (\(ns.substring(with: literal.range))) "
                                  + "with no origin in the same body: launch it through runModel(args:origin:…)")
                }
            }
        }
        XCTAssertGreaterThan(found, 10, "the literal scan found almost nothing: is the pattern broken?")
        for key in DesktopProcessLaunchSites.literalExemptions.keys {
            XCTAssertTrue(usedExemptions.contains(key), "literalExemptions lists \(key), which holds no model-path literal any more")
        }
    }

    /// A full model path opening a literal, and each proper prefix of one
    /// closed and composed with `+`.
    private static func literalPatterns() throws -> [NSRegularExpression] {
        var patterns: [NSRegularExpression] = []
        for path in ModelCommands.paths {
            let words = path.map { NSRegularExpression.escapedPattern(for: "\"\($0)\"") }
            let sep = #"\s*,\s*"#
            patterns.append(try NSRegularExpression(pattern: #"\[\s*"# + words.joined(separator: sep) + #"\s*[,\]]"#))
            for count in 1..<path.count {
                let prefix = words.prefix(count).joined(separator: sep)
                patterns.append(try NSRegularExpression(pattern: #"\[\s*"# + prefix + #"\s*\]\s*\+"#))
            }
        }
        return patterns
    }
}

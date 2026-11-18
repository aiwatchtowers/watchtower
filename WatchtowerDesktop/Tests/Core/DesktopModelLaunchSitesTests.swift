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

    /// A file that finds the CLI binary and builds a `Process` of its own.
    private static func launchesCLI(_ text: String) -> Bool {
        text.contains("findCLIPath") && (text.contains("Process()") || text.contains(".executableURL"))
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
        for path in DesktopProcessLaunchSites.nonArgvLiterals.keys {
            XCTAssertNotNil(files[path], "nonArgvLiterals lists \(path), which no longer exists")
        }
    }

    /// The round-1 string scan, kept as an extra net: a file with a
    /// string-array literal that starts with a model command path launches it
    /// through an entry that takes an origin — `runModel(`, or the review
    /// stream's `stream(args:origin:)` — or is a listed `Process` launch site
    /// that runs a model, whose origin `testEveryProcessLaunchOfTheCLIIsListed`
    /// checks.
    /// File-scoped: the literal is often built in one function and launched in
    /// another (`MeetingPrepViewModel.start`, `AutomationsCLI.args`).
    func testLiteralModelArgsUseRunModel() throws {
        let files = try Self.sourceFiles()
        let patterns = try ModelCommands.paths.map { path -> NSRegularExpression in
            let words = path.map { NSRegularExpression.escapedPattern(for: "\"\($0)\"") }
            return try NSRegularExpression(pattern: #"\[\s*"# + words.joined(separator: #"\s*,\s*"#) + #"(\s*[,\]])"#)
        }
        var found = 0
        for (path, text) in files {
            let range = NSRange(text.startIndex..., in: text)
            guard patterns.contains(where: { $0.firstMatch(in: text, range: range) != nil }) else { continue }
            found += 1
            if DesktopProcessLaunchSites.nonArgvLiterals[path] != nil { continue }
            if let site = DesktopProcessLaunchSites.sites[path], site.launch != .noModel { continue }
            XCTAssertTrue(text.contains("runModel(") || text.contains("stream(args: args, origin: ."),
                          "\(path) builds a model command's argv but never calls runModel(args:origin:…)")
        }
        XCTAssertGreaterThan(found, 10, "the literal scan found almost nothing: is the pattern broken?")
        for path in DesktopProcessLaunchSites.nonArgvLiterals.keys {
            let text = files[path] ?? ""
            let range = NSRange(text.startIndex..., in: text)
            XCTAssertTrue(patterns.contains { $0.firstMatch(in: text, range: range) != nil },
                          "nonArgvLiterals lists \(path), which holds no model-like literal any more")
        }
    }
}

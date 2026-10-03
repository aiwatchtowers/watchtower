import Foundation
import WatchtowerCore
import XCTest
@testable import WatchtowerDesktop

/// End to end against the real Go CLI built from this checkout
/// (`go build -o <tmp>/watchtower .`): a full index, a `--serve` update and
/// a deletion through `CodeIndexCenter`, and a `CodeSearchRun`. Skipped
/// when no Go toolchain is installed.
@MainActor
final class CodeNavRealCLITests: XCTestCase {
    nonisolated(unsafe) private static var binary: Result<URL, Error>?
    private var folder: URL!
    private var center: CodeIndexCenter?

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CodeNav
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent()
    }

    private static func goTool() -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let dirs = path.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/go/bin", "/usr/local/bin"]
        return dirs.map { $0 + "/go" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Builds the CLI once per run of the suite.
    private static func builtCLI() throws -> URL {
        if let binary { return try binary.get() }
        let result = Result { () throws -> URL in
            guard let go = goTool() else { throw XCTSkip("no Go toolchain to build the watchtower CLI") }
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("code-nav-cli-\(UUID().uuidString)/watchtower")
            let build = Process()
            build.executableURL = URL(fileURLWithPath: go)
            build.arguments = ["build", "-o", out.path, "."]
            build.currentDirectoryURL = repoRoot
            let log = Pipe()
            build.standardOutput = log
            build.standardError = log
            try build.run()
            let output = log.fileHandleForReading.readDataToEndOfFile()
            build.waitUntilExit()
            guard build.terminationStatus == 0 else {
                let message = String(bytes: output, encoding: .utf8) ?? "go build failed"
                throw NSError(domain: "go build", code: Int(build.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
            }
            return out
        }
        binary = result
        return try result.get()
    }

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("code-nav-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("pkg"), withIntermediateDirectories: true)
        try "package pkg\n\n// Hello greets.\nfunc Hello() string { return \"hi\" }\n"
            .write(to: folder.appendingPathComponent("pkg/hello.go"), atomically: true, encoding: .utf8)
        try "def greet():\n    return Hello()\n".write(to: folder.appendingPathComponent("greet.py"), atomically: true, encoding: .utf8)
        try "notes\n".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        center?.stopAll()
        center = nil
        try? FileManager.default.removeItem(at: folder)
    }

    func testIndexUpdateDeleteAndSearchWithTheRealCLI() async throws {
        let cli = try Self.builtCLI().path
        let env = ProcessInfo.processInfo.environment
        let center = CodeIndexCenter(resolveExecutable: { cli }, environment: { env }, debounce: .milliseconds(50))
        self.center = center
        center.markShown(workbenchID: 1, folder: folder)
        let index = center.index(for: 1)
        let ready = await eventually { index.state == .ready || { if case .failed = index.state { true } else { false } }() }
        XCTAssertTrue(ready)
        XCTAssertEqual(index.state, .ready)
        XCTAssertEqual(index.files.sorted(), ["greet.py", "notes.txt", "pkg/hello.go"])
        let hello = try XCTUnwrap(index.symbols(named: "Hello").first)
        XCTAssertEqual(hello.kind, .function)
        XCTAssertEqual(hello.path, "pkg/hello.go")
        XCTAssertEqual(hello.line, 4)
        XCTAssertEqual(hello.col, 6)
        XCTAssertEqual(index.symbols(in: "greet.py").map(\.name), ["greet"])

        try "package pkg\n\nfunc Added() {}\n".write(to: folder.appendingPathComponent("pkg/added.go"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("greet.py"))
        center.handle(FolderWatcher.Batch(paths: ["pkg/added.go", "greet.py"]), workbenchID: 1)
        let updated = await eventually { !index.symbols(named: "Added").isEmpty && !index.files.contains("greet.py") }
        XCTAssertTrue(updated, "files now: \(index.files)")
        XCTAssertEqual(index.state, .ready)
        XCTAssertEqual(index.symbols(named: "greet"), [])

        var matches: [CodeSearchMatch] = []
        var outcome: CodeSearchRun.Outcome?
        let run = CodeSearchRun.start(
            folder: folder, options: CodeSearchOptions(query: "Hello", word: true, caseSensitive: true),
            executable: cli, environment: env
        ) { matches.append($0) } onDone: { outcome = $0 }
        let searched = await eventually { outcome != nil }
        XCTAssertTrue(searched)
        XCTAssertEqual(outcome, .finished(CodeSearchDone(files: 3, matches: 2, truncated: false)))
        XCTAssertEqual(Set(matches.map(\.path)), ["pkg/hello.go"])
        XCTAssertEqual(matches.map(\.line).sorted(), [3, 4])
        withExtendedLifetime(run) {}
    }
}

import XCTest

/// Decision 7 of the background-AI-consent plan (#1886): `ConfigFileWriter`
/// is the only Swift code that writes `config.yaml` bytes, so every Desktop
/// writer goes through `ConfigFileLock` and re-reads inside it. The Go twin
/// is `TestConfigWriters_OnlyThroughWriteLock`.
final class ConfigWritersTests: XCTestCase {
    private let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Core
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // WatchtowerDesktop
        .appendingPathComponent("Sources")

    /// A file write call whose arguments (to the end of the line) name a
    /// config path. Deliberately broad: a false hit is cheap to see.
    static let configWrite =
        #"(write\(toFile:|write\(to:|FileHandle\(forWritingAtPath:|createFile\(atPath:|\bopen\(|\brename\()[^\n]*\b(configPath|configURL)\b"#

    static func offenders(in text: String) throws -> [Int] {
        let regex = try NSRegularExpression(pattern: configWrite)
        var lines: [Int] = []
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let code = line.trimmingCharacters(in: .whitespaces)
            if code.hasPrefix("//") { continue }
            if regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                lines.append(index + 1)
            }
        }
        return lines
    }

    func testOnlyConfigFileWriterWritesConfig() throws {
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let files = walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "the scan must find the sources")
        var writerHits = 0
        for file in files {
            let name = String(file.path.dropFirst(sources.path.count + 1))
            let hits = try Self.offenders(in: try String(contentsOf: file, encoding: .utf8))
            if file.lastPathComponent == "ConfigFileWriter.swift" {
                writerHits += hits.count
                continue
            }
            XCTAssertEqual(hits, [], "\(name): writes config.yaml outside ConfigFileWriter (use ConfigFileLock.withLock + ConfigFileWriter.write)")
        }
        XCTAssertGreaterThan(writerHits, 0, "the scan sees ConfigFileWriter's own write")
    }

    func testScanFlagsEachWriteForm() throws {
        let flagged = """
        try output.write(toFile: configPath, atomically: true, encoding: .utf8)
        try data.write(to: URL(fileURLWithPath: configPath))
        let handle = FileHandle(forWritingAtPath: configURL.path)
        FileManager.default.createFile(atPath: configPath, contents: nil)
        let fd = open(configPath, O_WRONLY)
        guard rename(staged, configPath) == 0 else { return }
        """
        XCTAssertEqual(try Self.offenders(in: flagged), [1, 2, 3, 4, 5, 6])
        let clean = """
        // try output.write(toFile: configPath, atomically: true, encoding: .utf8)
        let data = FileManager.default.contents(atPath: configPath)
        NSWorkspace.shared.open(url)
        try report.write(toFile: reportPath, atomically: true, encoding: .utf8)
        """
        XCTAssertEqual(try Self.offenders(in: clean), [])
    }
}

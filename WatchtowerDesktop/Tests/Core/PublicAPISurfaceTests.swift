import Foundation
import XCTest

/// The mobile Kit boundary on the Desktop side (mobile POC spec §2.1): only
/// the `WatchtowerDesktop` executable target depends on `WatchtowerSync`, and
/// `WatchtowerCore` stays Kit-free, so the Core test bundle is unchanged.
/// Grep tests over the sources and the manifest, so a stray import or
/// dependency fails here instead of quietly coupling Core to CloudKit.
final class PublicAPISurfaceTests: XCTestCase {
    /// …/WatchtowerDesktop, from …/WatchtowerDesktop/Tests/Core/<this file>.
    private static let desktopDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // …/Tests/Core
        .deletingLastPathComponent()  // …/Tests
        .deletingLastPathComponent()  // …/WatchtowerDesktop

    private static let kitModules = ["WatchtowerSync", "WatchtowerKit"]

    func testNoCoreSourceImportsTheKit() throws {
        let coreDir = Self.desktopDir.appendingPathComponent("Sources/WatchtowerCore")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: coreDir, includingPropertiesForKeys: nil))
        var scanned = 0
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let source = try String(contentsOf: url, encoding: .utf8)
            for line in source.split(separator: "\n") where Self.importsKit(line) {
                offenders.append("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertGreaterThan(scanned, 0, "WatchtowerCore sources must be reachable at \(coreDir.path)")
        XCTAssertEqual(offenders, [], "WatchtowerCore must not import the mobile Kit")
    }

    func testImportMatcherCatchesEveryImportForm() {
        XCTAssertTrue(Self.importsKit("import WatchtowerSync"))
        XCTAssertTrue(Self.importsKit("@testable import WatchtowerKit"))
        XCTAssertTrue(Self.importsKit("@_exported import WatchtowerSync"))
        XCTAssertTrue(Self.importsKit("  import struct WatchtowerSync.CloudRecord"))
        XCTAssertFalse(Self.importsKit("import WatchtowerCore"))
        XCTAssertFalse(Self.importsKit("// mentions WatchtowerSync in a comment"))
    }

    func testManifestKeepsCoreKitFreeAndTheAppOnWatchtowerSyncOnly() throws {
        let manifest = try String(
            contentsOf: Self.desktopDir.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let core = try XCTUnwrap(Self.targetBlock(named: "WatchtowerCore", in: manifest))
        for module in Self.kitModules {
            XCTAssertFalse(core.contains(module), "WatchtowerCore must not depend on \(module)")
        }
        let app = try XCTUnwrap(Self.targetBlock(named: "WatchtowerDesktop", in: manifest))
        XCTAssertTrue(app.contains(#".product(name: "WatchtowerSync", package: "WatchtowerKit")"#))
        XCTAssertFalse(app.contains(#".product(name: "WatchtowerKit""#), "the app takes WatchtowerSync only")
    }

    // MARK: - Helpers

    /// True for any import declaration (attributes and `import struct …`
    /// forms included) of a Kit module.
    private static func importsKit(_ line: some StringProtocol) -> Bool {
        let words = line.split { $0 == " " || $0 == "\t" }
        guard let importIndex = words.firstIndex(of: "import"),
              words[..<importIndex].allSatisfy({ $0.hasPrefix("@") }) else { return false }
        return words[words.index(after: importIndex)...].contains { word in
            kitModules.contains { word == $0 || word.hasPrefix($0 + ".") }
        }
    }

    /// The manifest text of the target declared as `name: "<target>",`
    /// right after a `.target(` / `.executableTarget(` opener (the package's
    /// own `name:` is skipped), up to the next target declaration.
    private static func targetBlock(named name: String, in manifest: String) -> Substring? {
        let openers = [".target(", ".executableTarget(", ".testTarget("]
        var searchStart = manifest.startIndex
        while let found = manifest.range(of: #"name: "\#(name)","#, range: searchStart..<manifest.endIndex) {
            searchStart = found.upperBound
            let before = manifest[..<found.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            guard openers.contains(where: { before.hasSuffix($0) }) else { continue }
            let rest = manifest[found.upperBound...]
            let end = openers.compactMap { rest.range(of: $0)?.lowerBound }.min() ?? rest.endIndex
            return rest[..<end]
        }
        return nil
    }
}

import XCTest
@testable import WatchtowerCore

/// `internal/reviewmap/testdata/chapters_golden.json` pins the chapters
/// today's Swift builder makes (keys, titles, paths, lines, core, build
/// order). Go's `reviewmap` reads the same file and must build the same
/// chapters, so saved `agent:<n>` and `dir:<dir>[#N]` keys keep matching
/// once the Swift builder is removed.
final class ReviewChaptersGoldenTests: XCTestCase {
    private struct Golden: Decodable {
        let cases: [Case]
    }

    private struct Case: Decodable {
        let name: String
        let files: [File]
        let agent: [Spec]
        let chapters: [Chapter]
    }

    private struct File: Decodable {
        let path: String
        let additions: Int
        let deletions: Int
        let collapsedReason: String?

        private enum CodingKeys: String, CodingKey {
            case path, additions, deletions
            case collapsedReason = "collapsed_reason"
        }
    }

    private struct Spec: Decodable {
        let title: String
        let paths: [String]
        let core: Bool
    }

    private struct Chapter: Codable, Equatable {
        let key: String
        let title: String
        let paths: [String]
        let changedLines: Int
        let core: Bool

        private enum CodingKeys: String, CodingKey {
            case key, title, paths, core
            case changedLines = "changed_lines"
        }
    }

    private static func golden() throws -> Golden {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/reviewmap/testdata/chapters_golden.json")
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }

    func testSwiftChaptersMatchTheSharedGolden() throws {
        let golden = try Self.golden()
        XCTAssertGreaterThanOrEqual(golden.cases.count, 5)
        for item in golden.cases {
            let files = item.files.map {
                ReviewDiffFile(
                    path: $0.path, additions: $0.additions, deletions: $0.deletions, collapsedReason: $0.collapsedReason
                )
            }
            let agent = item.agent.map { ReviewChapterSpec(title: $0.title, paths: $0.paths, core: $0.core, lenses: nil) }
            let got = ReviewChapters.resolve(files, agent: agent, ai: []).map {
                Chapter(key: $0.key, title: $0.title, paths: $0.paths, changedLines: $0.changedLines, core: $0.core)
            }
            if got != item.chapters {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                let actual = String(data: try encoder.encode(got), encoding: .utf8) ?? ""
                XCTFail("case \(item.name): Swift builds\n\(actual)")
            }
        }
    }
}

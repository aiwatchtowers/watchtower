import Foundation
import XCTest

/// The two skill files every chat-surface prompt test needs, so a test can
/// assert that every enabled skill reaches the surface's prompt. Shared by
/// the Idea/Meeting/Track skills prompt tests; `SituationChatPromptTests` and
/// `TargetChatViewModelTests` predate it and keep their own local helpers.
enum SkillsPromptFixtures {
    static let untangleName = "thread-untangle"
    static let breakdownName = "target-breakdown"
    static let untangleLine = "thread-untangle — Reconstruct who asked what in a tangled thread."
    static let breakdownLine = "target-breakdown — Decompose a target into sub-targets."

    /// A skills directory holding two enabled skills.
    static func makePair(_ test: XCTestCase) throws -> String {
        try makeDir(test, files: [
            "\(untangleName).md": """
                ---
                description: Reconstruct who asked what in a tangled thread.
                ---
                Body.
                """,
            "\(breakdownName).md": """
                ---
                description: Decompose a target into sub-targets.
                ---
                Body.
                """
        ])
    }

    static func makeEmptyDir(_ test: XCTestCase) throws -> String {
        try makeDir(test, files: [:])
    }

    private static func makeDir(_ test: XCTestCase, files: [String: String]) throws -> String {
        let dir = NSTemporaryDirectory() + "skills_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, content) in files {
            try Data(content.utf8).write(to: URL(fileURLWithPath: dir + "/" + name))
        }
        test.addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }
}

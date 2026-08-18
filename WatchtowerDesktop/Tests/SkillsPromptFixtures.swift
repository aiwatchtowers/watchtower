import Foundation
import XCTest

/// The two skill files every chat-surface prompt test needs — one per persona,
/// so a test can assert both that the surface's own persona is listed and that
/// the other persona's skill is not. Shared by the Idea/Meeting/Track skills
/// prompt tests; `SituationChatPromptTests` and `TargetChatViewModelTests`
/// predate it and keep their own local helpers.
enum SkillsPromptFixtures {
    static let secretaryName = "thread-untangle"
    static let assistantName = "target-breakdown"
    static let secretaryLine = "thread-untangle — Reconstruct who asked what in a tangled thread."
    static let assistantLine = "target-breakdown — Decompose a target into sub-targets."

    /// A skills directory holding one enabled secretary skill and one enabled
    /// assistant skill.
    static func makePersonaPair(_ test: XCTestCase) throws -> String {
        try makeDir(test, files: [
            "\(secretaryName).md": """
                ---
                description: Reconstruct who asked what in a tangled thread.
                persona: secretary
                ---
                Body.
                """,
            "\(assistantName).md": """
                ---
                description: Decompose a target into sub-targets.
                persona: assistant
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

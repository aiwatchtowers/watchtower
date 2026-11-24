@testable import WatchtowerChatText
import XCTest

/// A code artifact's Markdown: the fence outlasts any run of backticks in the code, so the code never closes it and
/// spills out as Markdown; code no fence can hold has no Markdown at all (a task's output in the viewer, #2201 T4).
final class ChatArtifactMarkdownTests: XCTestCase {
    private func code(_ content: String, language: String? = nil) -> String? {
        ChatArtifactActions.markdown(ArtifactDraft(key: "k", kind: "code", title: "t",
                                                   meta: language.map { ["language": $0] } ?? [:],
                                                   content: content, isComplete: true))
    }

    func testPlainCodeKeepsThreeBackticks() {
        XCTAssertEqual(code("let a = 1", language: "swift"), "```swift\nlet a = 1\n```")
    }

    func testFenceOutlastsBackticksInTheCode() {
        XCTAssertEqual(code("a\n```\n# not a heading\n````x"), "`````\na\n```\n# not a heading\n````x\n`````")
        XCTAssertEqual(MarkdownDocument.parse(code("x\n```\n[link](https://example.com)") ?? ""),
                       [.code(language: nil, code: "x\n```\n[link](https://example.com)")])
    }

    func testRunNoFenceCanHoldIsLiteralNotMarkdown() {
        let ticks = String(repeating: "`", count: ChatArtifactActions.maxFence)
        for content in [
            "a\n\(ticks)\n# not a heading\n[link](https://example.com)",
            "a\r\(ticks)\r# h",
            "a\r\n\(ticks)\r\n# h\r\n",
            "\n\n\(ticks)\n\n"
        ] {
            XCTAssertNil(code(content, language: "text"), content.debugDescription)
            XCTAssertNil(ChatArtifactActions.codeFence(for: content))
        }
    }

    func testLongestRunAFenceStillHolds() {
        let run = String(repeating: "`", count: ChatArtifactActions.maxFence - 1)
        let fence = String(repeating: "`", count: ChatArtifactActions.maxFence)
        XCTAssertEqual(ChatArtifactActions.codeFence(for: "b\n\(run)"), fence)
        XCTAssertEqual(MarkdownDocument.parse(code("b\n\(run)") ?? ""), [.code(language: nil, code: "b\n\(run)")])
    }

    func testOtherKindsAreUntouched() {
        let draft = ArtifactDraft(key: "k", kind: "document", title: "t", meta: [:], content: "```", isComplete: true)
        XCTAssertEqual(ChatArtifactActions.markdown(draft), "```")
    }
}

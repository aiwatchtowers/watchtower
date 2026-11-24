@testable import WatchtowerChatText
import XCTest

/// A code artifact's Markdown: the fence outlasts any run of backticks in the code, so the code never closes it and
/// spills out as Markdown (a task's output shown in the viewer, #2201 T4).
final class ChatArtifactMarkdownTests: XCTestCase {
    private func code(_ content: String, language: String? = nil) -> String {
        ChatArtifactActions.markdown(ArtifactDraft(key: "k", kind: "code", title: "t",
                                                   meta: language.map { ["language": $0] } ?? [:],
                                                   content: content, isComplete: true))
    }

    func testPlainCodeKeepsThreeBackticks() {
        XCTAssertEqual(code("let a = 1", language: "swift"), "```swift\nlet a = 1\n```")
    }

    func testFenceOutlastsBackticksInTheCode() {
        XCTAssertEqual(code("a\n```\n# not a heading\n````x"), "`````\na\n```\n# not a heading\n````x\n`````")
        XCTAssertEqual(MarkdownDocument.parse(code("x\n```\n[link](https://example.com)")),
                       [.code(language: nil, code: "x\n```\n[link](https://example.com)")])
    }

    func testOtherKindsAreUntouched() {
        let draft = ArtifactDraft(key: "k", kind: "document", title: "t", meta: [:], content: "```", isComplete: true)
        XCTAssertEqual(ChatArtifactActions.markdown(draft), "```")
    }
}

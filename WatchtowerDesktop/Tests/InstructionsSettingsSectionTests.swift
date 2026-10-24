import XCTest
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// Settings → Profile → Instructions: the section's state, its reload when a
/// chat remembers a line, and the from-chat list.
@MainActor
final class InstructionsSettingsSectionTests: XCTestCase {
    private func body(chat: String, lines: String = "[]") -> Data {
        Data(#"{"ok":true,"limit":1000,"global":{"session":"s","procedure":"p","chat":"\#(chat)"},"suggestions":[],"chat_lines":\#(lines)}"#.utf8)
    }

    private func model(_ runner: FakeCLIRunner) -> InstructionsSettingsModel {
        InstructionsSettingsModel(cli: WorkbenchCLI(runner: runner))
    }

    func testLoadReadsChatTextAndLines() async {
        let lines = #"[{"id":4,"line":"short answers","conversation_id":9,"message_id":2,"added_at":"2026-10-24T10:00:00Z"}]"#
        let m = model(FakeCLIRunner(stdout: body(chat: "short answers", lines: lines)))
        await m.load()
        XCTAssertEqual(m.state?.global.chat, "short answers")
        XCTAssertEqual(m.state?.chatLines.map(\.id), [4])
    }

    func testSavingChatTextCallsSetFieldChatOverStdin() async {
        let runner = FakeCLIRunner(stdout: body(chat: "be brief"))
        let m = model(runner)
        await m.save(.chat, body: "be brief")
        XCTAssertEqual(runner.invocations, [["instructions", "set", "--field", "chat", "--stdin", "--json"]])
        XCTAssertEqual(runner.stdinInputs.compactMap { String(bytes: $0, encoding: .utf8) }, ["be brief"])
        XCTAssertNil(m.drafts[.chat])
    }

    func testRevisionChangeReloadsSavedState() async {
        let runner = FakeCLIRunner(stdout: body(chat: "old"))
        let m = model(runner)
        await m.load()
        let reloaded = FakeCLIRunner(stdout: body(chat: "old\\nnew line"))
        m.replaceCLI(WorkbenchCLI(runner: reloaded))
        await m.rememberRevisionChanged()
        XCTAssertEqual(m.state?.global.chat, "old\nnew line")
        XCTAssertEqual(reloaded.invocations.count, 1)
    }

    func testRevisionChangeDropsUnsavedChatDraftAndSaysSo() async {
        let m = model(FakeCLIRunner(stdout: body(chat: "old")))
        await m.load()
        m.drafts[.chat] = "my edit"
        m.drafts[.session] = "session edit"
        await m.rememberRevisionChanged()
        XCTAssertNil(m.drafts[.chat], "a draft over the old chat text would overwrite the new line on Save")
        XCTAssertEqual(m.drafts[.session], "session edit", "remember never touches the session text")
        XCTAssertNotNil(m.notice)
    }

    func testRevisionChangeWithoutDraftSaysNothing() async {
        let m = model(FakeCLIRunner(stdout: body(chat: "old")))
        await m.load()
        await m.rememberRevisionChanged()
        XCTAssertNil(m.notice)
    }

    func testOpenChatLinkOnlyWhenLineHasConversation() {
        let with = OwnerInstructionChatLine(id: 1, line: "a", conversationID: 3, messageID: nil, addedAt: "")
        let without = OwnerInstructionChatLine(id: 2, line: "b", conversationID: nil, messageID: nil, addedAt: "")
        XCTAssertEqual(InstructionsSettingsModel.openChatTarget(with), 3)
        XCTAssertNil(InstructionsSettingsModel.openChatTarget(without))
    }
}

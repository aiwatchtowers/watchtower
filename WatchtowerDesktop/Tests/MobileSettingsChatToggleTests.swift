import XCTest
import WatchtowerCore
@testable import WatchtowerDesktop

/// Settings → Mobile → a phone: the Chat toggle (the `chat` grant, spec
/// 2026-11-15 §5, mockup 4b). On by default (ask #1340); each change is one
/// `hub allow <device> chat --json`, `--revoke` to turn it off.
@MainActor
final class MobileSettingsChatToggleTests: XCTestCase {
    typealias Model = MobileSettingsModel
    private var cli: ScriptedHubCLI!
    private var defaults: UserDefaults!
    private let suite = "WatchtowerDesktopTests.mobileSettingsChatToggle"

    override func setUp() async throws {
        cli = ScriptedHubCLI()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    private func loaded(_ phones: String...) async -> Model {
        cli.status(MobileHubFixture.running)
        cli.phones("[" + phones.joined(separator: ",") + "]")
        let model = Model(cli: cli, defaults: defaults, now: { Date() }, sleep: { _ in })
        await model.load()
        return model
    }

    private func rows(_ model: Model) -> [Model.PhoneRow] {
        guard case .phones(let rows) = model.state else { return [] }
        return rows
    }

    /// A phone's JSON with `chat` as its `chat_allowed` value: `true`,
    /// `false`, or "" to leave the key out (a hub that does not report it).
    private func phone(_ id: String, chat: String) -> String {
        let base = MobileHubFixture.phone(id: id, name: "Phone \(id.prefix(1))", transport: "relay")
        guard !chat.isEmpty else { return base }
        return String(base.dropLast()) + #","chat_allowed":\#(chat)}"#
    }

    func testCopy() {
        XCTAssertEqual(Model.chatTitle, "Chat")
        XCTAssertEqual(Model.chatCaption, "Chat on this iPhone: ask, approve with Permissions")
        XCTAssertEqual(Model.chatGrant, "chat")
        XCTAssertEqual(Model.couldNotChange("chat", name: "Phone A", why: "No such phone."),
                       "Couldn't change chat for Phone A. No such phone.")
    }

    func testToggleReadsTheGrantOnByDefault() async {
        let model = await loaded(phone("AAAA0001", chat: ""), phone("BBBB0002", chat: "false"), phone("CCCC0003", chat: "true"))
        let chat = Dictionary(uniqueKeysWithValues: rows(model).map { ($0.id, $0.chat) })
        XCTAssertEqual(chat["AAAA0001"], true, "a hub that does not report it: on, the grant's default")
        XCTAssertEqual(chat["BBBB0002"], false)
        XCTAssertEqual(chat["CCCC0003"], true)
    }

    func testToggleCallsTheCLI() async throws {
        let model = await loaded(phone("AAAA0001", chat: "true"))
        let row = try XCTUnwrap(rows(model).first)

        await model.setChat(row, false)
        await model.setChat(row, true)

        XCTAssertEqual(cli.writes, [
            ["hub", "allow", "AAAA0001", "chat", "--json", "--revoke"],
            ["hub", "allow", "AAAA0001", "chat", "--json"]
        ])

        cli.fail(MobileHubCLI.allowArgs("AAAA0001", "chat", false), stderr: "Error: no such phone")
        await model.setChat(row, false)
        XCTAssertEqual(model.notice, "Couldn't change chat for Phone A. No such phone.")
    }
}

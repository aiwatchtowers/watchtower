import XCTest
@testable import WatchtowerDesktop

@MainActor
final class EmailSetupChatViewModelTests: XCTestCase {

    private func makeSnapshot(
        host: String = "",
        hasPassword: Bool = false,
        lastConnectionError: String? = nil
    ) -> ImapFormSnapshot {
        ImapFormSnapshot(
            host: host, portText: "993", security: "ssl",
            username: "user@example.com", folder: "INBOX", label: "",
            hasPassword: hasPassword, lastConnectionError: lastConnectionError
        )
    }

    private func block(_ json: String) -> String {
        "```watchtower-imap-settings\n\(json)\n```"
    }

    // MARK: - Parser

    func testParserFullBlock() {
        let raw = "Here you go.\n" + block(
            #"{"host": "imap.gmail.com", "port": 993, "security": "ssl", "username": "u@gmail.com", "folder": "INBOX"}"#
        )
        let parsed = ImapSettingsParser.parse(raw)

        XCTAssertEqual(parsed.patch, ImapSettingsPatch(
            host: "imap.gmail.com", port: 993, security: "ssl",
            username: "u@gmail.com", folder: "INBOX", label: nil
        ))
        XCTAssertEqual(parsed.text, "Here you go.")
    }

    func testParserPartialBlock() {
        let parsed = ImapSettingsParser.parse(block(#"{"host": "imap.yandex.com"}"#))

        XCTAssertEqual(parsed.patch, ImapSettingsPatch(host: "imap.yandex.com"))
    }

    func testParserMalformedJSONIsNoOp() {
        let parsed = ImapSettingsParser.parse("Try this.\n" + block("{not json at all"))

        XCTAssertNil(parsed.patch)
        XCTAssertEqual(parsed.text, "Try this.", "even a malformed block is machine junk — stripped from display")
    }

    func testParserNoBlockLeavesTextUntouched() {
        let parsed = ImapSettingsParser.parse("Where is your mailbox hosted?")

        XCTAssertNil(parsed.patch)
        XCTAssertEqual(parsed.text, "Where is your mailbox hosted?")
    }

    func testParserDropsPasswordKey() {
        let parsed = ImapSettingsParser.parse(block(
            #"{"host": "imap.mail.ru", "password": "hunter2"}"#
        ))

        XCTAssertEqual(parsed.patch, ImapSettingsPatch(host: "imap.mail.ru"),
                       "a password key must be dropped — the patch type cannot even carry it")
        XCTAssertFalse(parsed.text.contains("hunter2"))
    }

    func testParserStripsBlockFromDisplayedText() {
        let raw = "Gmail needs these settings:\n\n" + block(#"{"host": "imap.gmail.com"}"#) + "\n\nNow press Test and Connect."
        let parsed = ImapSettingsParser.parse(raw)

        XCTAssertFalse(parsed.text.contains("watchtower-imap-settings"))
        XCTAssertFalse(parsed.text.contains("imap.gmail.com"))
        XCTAssertTrue(parsed.text.contains("Gmail needs these settings:"))
        XCTAssertTrue(parsed.text.contains("Now press Test and Connect."))
    }

    func testParserLastOfSeveralBlocksWins() {
        let raw = block(#"{"host": "imap.first.com"}"#) + "\nActually, better:\n" + block(#"{"host": "imap.second.com"}"#)
        let parsed = ImapSettingsParser.parse(raw)

        XCTAssertEqual(parsed.patch?.host, "imap.second.com")
        XCTAssertFalse(parsed.text.contains("imap.first.com"), "all blocks are stripped, not just the last")
    }

    func testParserRejectsUnknownSecurityValue() {
        let parsed = ImapSettingsParser.parse(block(#"{"host": "imap.x.com", "security": "tls13"}"#))

        XCTAssertEqual(parsed.patch, ImapSettingsPatch(host: "imap.x.com"))
        XCTAssertNil(parsed.patch?.security)
    }

    func testParserAcceptsPortAsString() {
        let parsed = ImapSettingsParser.parse(block(#"{"port": "143", "security": "starttls"}"#))

        XCTAssertEqual(parsed.patch, ImapSettingsPatch(port: 143, security: "starttls"))
    }

    // MARK: - Prompt privacy

    /// The privacy boundary is structural: `ImapFormSnapshot` has no password
    /// slot, so the prompt can only ever carry the filled/empty marker.
    func testFormStateBlockCarriesOnlyPasswordFilledMarker() {
        let filled = EmailSetupChatViewModel.formStateBlock(makeSnapshot(host: "imap.gmail.com", hasPassword: true))
        XCTAssertTrue(filled.contains("Password field: filled"))

        let empty = EmailSetupChatViewModel.formStateBlock(makeSnapshot(hasPassword: false))
        XCTAssertTrue(empty.contains("Password field: empty"))
    }

    func testSendCarriesFormStateAndPasswordMarkerOnly() async throws {
        // The form's SecureField holds this value — it never enters the
        // snapshot (no field for it), so it cannot appear in any prompt.
        let formPassword = "s3cr3t-hunter2"
        let mock = MockClaudeService(events: [.text("ok"), .done])
        let vm = EmailSetupChatViewModel(aiService: mock)

        vm.inputText = "у меня джимейл"
        vm.send(snapshot: makeSnapshot(host: "imap.gmail.com", hasPassword: true))
        try await waitUntil { !vm.isStreaming }

        let prompt = try XCTUnwrap(mock.prompts.first)
        XCTAssertTrue(prompt.contains("=== CURRENT FORM STATE ==="))
        XCTAssertTrue(prompt.contains("Host: imap.gmail.com"))
        XCTAssertTrue(prompt.contains("Password field: filled"))
        XCTAssertTrue(prompt.hasSuffix("у меня джимейл"), "user text follows the form state")
        XCTAssertFalse(prompt.contains(formPassword))
    }

    func testSystemPromptNeverContainsAPasswordSlot() {
        XCTAssertTrue(EmailSetupChatViewModel.systemPrompt.contains("NEVER ask for, accept, or repeat"))
        XCTAssertFalse(EmailSetupChatViewModel.systemPrompt.contains(#""password":"#),
                       "the settings-block example must not teach a password key")
    }

    // MARK: - Settings application

    func testTurnCompleteAppliesSettingsAndStripsBlock() async throws {
        let reply = "Gmail it is — I filled in the settings. Now create an app password.\n"
            + block(#"{"host": "imap.gmail.com", "port": 993, "security": "ssl", "folder": "INBOX"}"#)
        let mock = MockClaudeService(events: [.turnComplete(reply), .done])
        let vm = EmailSetupChatViewModel(aiService: mock)
        var applied: ImapSettingsPatch?
        vm.onApplySettings = { applied = $0 }

        vm.inputText = "gmail"
        vm.send(snapshot: makeSnapshot())
        try await waitUntil { !vm.isStreaming }

        XCTAssertEqual(applied, ImapSettingsPatch(
            host: "imap.gmail.com", port: 993, security: "ssl", folder: "INBOX"
        ))
        let displayed = try XCTUnwrap(vm.messages.last)
        XCTAssertFalse(displayed.text.contains("watchtower-imap-settings"))
        XCTAssertTrue(displayed.text.contains("I filled in the settings"))
    }

    func testBlockOnlyReplyShowsPlaceholder() async throws {
        let mock = MockClaudeService(events: [.turnComplete(block(#"{"host": "imap.zoho.com"}"#)), .done])
        let vm = EmailSetupChatViewModel(aiService: mock)
        var applied: ImapSettingsPatch?
        vm.onApplySettings = { applied = $0 }

        vm.inputText = "zoho"
        vm.send(snapshot: makeSnapshot())
        try await waitUntil { !vm.isStreaming }

        XCTAssertEqual(applied?.host, "imap.zoho.com")
        XCTAssertEqual(vm.messages.last?.text, "(filled in the settings on the left)")
    }

    func testStreamErrorDoesNotApplyPartialSettings() async throws {
        struct Boom: Error {}
        let vm = EmailSetupChatViewModel(aiService: MockClaudeService(error: Boom()))
        var applied: ImapSettingsPatch?
        vm.onApplySettings = { applied = $0 }

        vm.inputText = "gmail"
        vm.send(snapshot: makeSnapshot())
        try await waitUntil { !vm.isStreaming }

        XCTAssertNil(applied)
        XCTAssertNotNil(vm.errorMessage)
    }

    // MARK: - Ephemeral chat behavior

    func testGreetingIsLocalAndNeverSentToAI() {
        let mock = MockClaudeService()
        let vm = EmailSetupChatViewModel(aiService: mock)

        vm.seedGreetingIfNeeded()
        vm.seedGreetingIfNeeded()

        XCTAssertEqual(vm.messages.count, 1, "greeting seeds once")
        XCTAssertEqual(vm.messages.first?.role, .assistant)
        XCTAssertTrue(mock.prompts.isEmpty, "the greeting is local — no AI call")
    }

    func testConnectionErrorTurnCarriesErrorAndSnapshot() async throws {
        let mock = MockClaudeService(events: [.text("Use an app password."), .done])
        let vm = EmailSetupChatViewModel(aiService: mock)

        vm.sendConnectionError(
            "AUTHENTICATIONFAILED invalid credentials",
            snapshot: makeSnapshot(host: "imap.gmail.com", hasPassword: true, lastConnectionError: "AUTHENTICATIONFAILED invalid credentials")
        )
        try await waitUntil { !vm.isStreaming }

        XCTAssertEqual(vm.messages.first?.role, .user)
        XCTAssertTrue(try XCTUnwrap(vm.messages.first?.text).contains("AUTHENTICATIONFAILED"))
        let prompt = try XCTUnwrap(mock.prompts.first)
        XCTAssertTrue(prompt.contains("Last connection error: AUTHENTICATIONFAILED invalid credentials"))
        XCTAssertTrue(prompt.contains("=== CURRENT FORM STATE ==="))
    }

    // MARK: - Helpers

    private func waitUntil(_ cond: @escaping () -> Bool) async throws {
        for _ in 0..<200 where !cond() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(cond(), "condition not met within 2s")
    }
}

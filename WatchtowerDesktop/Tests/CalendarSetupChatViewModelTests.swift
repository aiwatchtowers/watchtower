import XCTest
@testable import WatchtowerDesktop

@MainActor
final class CalendarSetupChatViewModelTests: XCTestCase {

    private func makeSnapshot(
        caldavURL: String = "",
        hasPassword: Bool = false,
        hasFeedURL: Bool = false,
        lastConnectionError: String? = nil
    ) -> CalendarFormSnapshot {
        CalendarFormSnapshot(
            caldavURL: caldavURL, username: "user@example.com", label: "",
            hasPassword: hasPassword, hasFeedURL: hasFeedURL,
            lastConnectionError: lastConnectionError
        )
    }

    private func block(_ json: String) -> String {
        "```watchtower-caldav-settings\n\(json)\n```"
    }

    // MARK: - Parser

    func testParserFullBlock() {
        let raw = "Here you go.\n" + block(
            #"{"url": "https://caldav.icloud.com", "username": "u@icloud.com"}"#
        )
        let parsed = CalendarSettingsParser.parse(raw)

        XCTAssertEqual(parsed.patch, CalendarSettingsPatch(
            url: "https://caldav.icloud.com", username: "u@icloud.com"
        ))
        XCTAssertEqual(parsed.text, "Here you go.")
    }

    func testParserPartialBlock() {
        let parsed = CalendarSettingsParser.parse(block(#"{"url": "https://caldav.yandex.ru"}"#))

        XCTAssertEqual(parsed.patch, CalendarSettingsPatch(url: "https://caldav.yandex.ru"))
    }

    func testParserMalformedJSONIsNoOp() {
        let parsed = CalendarSettingsParser.parse("Try this.\n" + block("{not json at all"))

        XCTAssertNil(parsed.patch)
        XCTAssertEqual(parsed.text, "Try this.", "even a malformed block is machine junk — stripped from display")
    }

    func testParserNoBlockLeavesTextUntouched() {
        let parsed = CalendarSettingsParser.parse("Which calendar do you use?")

        XCTAssertNil(parsed.patch)
        XCTAssertEqual(parsed.text, "Which calendar do you use?")
    }

    /// A password / feed_url / ics_url key must be dropped — the patch type
    /// cannot even carry a credential.
    func testParserDropsCredentialKeys() {
        let parsed = CalendarSettingsParser.parse(block(
            #"{"url": "https://caldav.fastmail.com", "password": "hunter2", "feed_url": "https://x/secret.ics", "ics_url": "https://y/secret.ics"}"#
        ))

        XCTAssertEqual(parsed.patch, CalendarSettingsPatch(url: "https://caldav.fastmail.com"))
        XCTAssertFalse(parsed.text.contains("hunter2"))
        XCTAssertFalse(parsed.text.contains("secret.ics"))
    }

    func testParserStripsBlockFromDisplayedText() {
        let raw = "iCloud needs these settings:\n\n" + block(#"{"url": "https://caldav.icloud.com"}"#)
            + "\n\nNow create an app-specific password."
        let parsed = CalendarSettingsParser.parse(raw)

        XCTAssertFalse(parsed.text.contains("watchtower-caldav-settings"))
        XCTAssertFalse(parsed.text.contains("caldav.icloud.com"))
        XCTAssertTrue(parsed.text.contains("iCloud needs these settings:"))
        XCTAssertTrue(parsed.text.contains("Now create an app-specific password."))
    }

    func testParserLastOfSeveralBlocksWins() {
        let raw = block(#"{"url": "https://first.example.com"}"#) + "\nActually, better:\n"
            + block(#"{"url": "https://second.example.com"}"#)
        let parsed = CalendarSettingsParser.parse(raw)

        XCTAssertEqual(parsed.patch?.url, "https://second.example.com")
        XCTAssertFalse(parsed.text.contains("first.example.com"), "all blocks are stripped, not just the last")
    }

    // MARK: - Prompt privacy

    /// The privacy boundary is structural: `CalendarFormSnapshot` has no
    /// password slot and no feed-URL slot, so the prompt can only ever carry
    /// the filled/empty markers.
    func testFormStateBlockCarriesOnlyCredentialFilledMarkers() {
        let filled = CalendarSetupChatViewModel.formStateBlock(
            makeSnapshot(caldavURL: "https://caldav.icloud.com", hasPassword: true, hasFeedURL: true)
        )
        XCTAssertTrue(filled.contains("Password field: filled"))
        XCTAssertTrue(filled.contains("ICS feed URL field: filled"))

        let empty = CalendarSetupChatViewModel.formStateBlock(makeSnapshot())
        XCTAssertTrue(empty.contains("Password field: empty"))
        XCTAssertTrue(empty.contains("ICS feed URL field: empty"))
    }

    func testSendCarriesFormStateAndNeverTheCredentialValues() async throws {
        // The form's SecureField and ICS field hold these values — they never
        // enter the snapshot (no fields for them), so they cannot appear in
        // any prompt.
        let formPassword = "s3cr3t-hunter2"
        let secretFeedURL = "https://calendar.google.com/calendar/ical/private-abc123/basic.ics"
        let mock = MockClaudeService(events: [.text("ok"), .done])
        let vm = CalendarSetupChatViewModel(aiService: mock)

        vm.inputText = "у меня айклауд"
        vm.send(snapshot: makeSnapshot(
            caldavURL: "https://caldav.icloud.com", hasPassword: true, hasFeedURL: true
        ))
        try await waitUntil { !vm.isStreaming }

        let prompt = try XCTUnwrap(mock.prompts.first)
        XCTAssertTrue(prompt.contains("=== CURRENT FORM STATE ==="))
        XCTAssertTrue(prompt.contains("CalDAV server URL: https://caldav.icloud.com"))
        XCTAssertTrue(prompt.contains("Password field: filled"))
        XCTAssertTrue(prompt.contains("ICS feed URL field: filled"))
        XCTAssertTrue(prompt.hasSuffix("у меня айклауд"), "user text follows the form state")
        XCTAssertFalse(prompt.contains(formPassword))
        XCTAssertFalse(prompt.contains(secretFeedURL))
    }

    func testSystemPromptNeverTeachesACredentialKey() {
        let prompt = CalendarSetupChatViewModel.systemPrompt
        XCTAssertTrue(prompt.contains("NEVER ask for, accept, or repeat"))
        XCTAssertFalse(prompt.contains(#""password":"#),
                       "the settings-block example must not teach a password key")
        XCTAssertFalse(prompt.contains(#""feed_url":"#),
                       "the settings-block example must not teach a feed-URL key")
    }

    // MARK: - Settings application

    func testTurnCompleteAppliesSettingsAndStripsBlock() async throws {
        let reply = "iCloud it is — I filled in the settings. Now create an app-specific password.\n"
            + block(#"{"url": "https://caldav.icloud.com", "username": "u@icloud.com"}"#)
        let mock = MockClaudeService(events: [.turnComplete(reply), .done])
        let vm = CalendarSetupChatViewModel(aiService: mock)
        var applied: CalendarSettingsPatch?
        vm.onApplySettings = { applied = $0 }

        vm.inputText = "icloud"
        vm.send(snapshot: makeSnapshot())
        try await waitUntil { !vm.isStreaming }

        XCTAssertEqual(applied, CalendarSettingsPatch(
            url: "https://caldav.icloud.com", username: "u@icloud.com"
        ))
        let displayed = try XCTUnwrap(vm.messages.last)
        XCTAssertFalse(displayed.text.contains("watchtower-caldav-settings"))
        XCTAssertTrue(displayed.text.contains("I filled in the settings"))
    }

    func testBlockOnlyReplyShowsPlaceholder() async throws {
        let mock = MockClaudeService(
            events: [.turnComplete(block(#"{"url": "https://caldav.fastmail.com"}"#)), .done]
        )
        let vm = CalendarSetupChatViewModel(aiService: mock)
        var applied: CalendarSettingsPatch?
        vm.onApplySettings = { applied = $0 }

        vm.inputText = "fastmail"
        vm.send(snapshot: makeSnapshot())
        try await waitUntil { !vm.isStreaming }

        XCTAssertEqual(applied?.url, "https://caldav.fastmail.com")
        XCTAssertEqual(vm.messages.last?.text, "(filled in the settings on the left)")
    }

    func testStreamErrorDoesNotApplyPartialSettings() async throws {
        struct Boom: Error {}
        let vm = CalendarSetupChatViewModel(aiService: MockClaudeService(error: Boom()))
        var applied: CalendarSettingsPatch?
        vm.onApplySettings = { applied = $0 }

        vm.inputText = "icloud"
        vm.send(snapshot: makeSnapshot())
        try await waitUntil { !vm.isStreaming }

        XCTAssertNil(applied)
        XCTAssertNotNil(vm.errorMessage)
    }

    // MARK: - Ephemeral chat behavior

    func testGreetingIsLocalAndNeverSentToAI() {
        let mock = MockClaudeService()
        let vm = CalendarSetupChatViewModel(aiService: mock)

        vm.seedGreetingIfNeeded()
        vm.seedGreetingIfNeeded()

        XCTAssertEqual(vm.messages.count, 1, "greeting seeds once")
        XCTAssertEqual(vm.messages.first?.role, .assistant)
        XCTAssertTrue(mock.prompts.isEmpty, "the greeting is local — no AI call")
    }

    func testConnectionErrorTurnCarriesErrorAndSnapshot() async throws {
        let mock = MockClaudeService(events: [.text("Use an app-specific password."), .done])
        let vm = CalendarSetupChatViewModel(aiService: mock)

        vm.sendConnectionError(
            "401 Unauthorized",
            snapshot: makeSnapshot(
                caldavURL: "https://caldav.icloud.com", hasPassword: true,
                lastConnectionError: "401 Unauthorized"
            )
        )
        try await waitUntil { !vm.isStreaming }

        XCTAssertEqual(vm.messages.first?.role, .user)
        XCTAssertTrue(try XCTUnwrap(vm.messages.first?.text).contains("401 Unauthorized"))
        let prompt = try XCTUnwrap(mock.prompts.first)
        XCTAssertTrue(prompt.contains("Last connection error: 401 Unauthorized"))
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

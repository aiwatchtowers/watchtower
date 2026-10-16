import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Records every argv and answers a fixed output, or throws. No process is spawned.
private final class StubGuideRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    private let output: String?

    init(output: String?) { self.output = output }

    var recorded: [[String]] { lock.withLock { calls } }

    func run(args: [String]) async throws -> Data {
        lock.withLock { calls.append(args) }
        guard let output else { throw CLIRunnerError.binaryNotFound }
        return Data(output.utf8)
    }
}

/// The ⌘/ Ask Watchtower panel's center and its help chat (spec
/// 2026-10-16 "Instant matches", "Asking (the help chat)").
@MainActor
final class AskCenterTests: XCTestCase {
    private static let fixture = """
    {"version":"dev","base_url":"https://example.com/guide/","catalog":"- features/calendar.md — Calendar",
     "sections":[
      {"page":"features/calendar.md","page_title":"Calendar","heading":"Recordings","anchor":"recordings","level":2,
       "text":"Record a meeting from its card."},
      {"page":"features/calendar.md","page_title":"Calendar","heading":"Get a recap","anchor":"get-a-recap","level":2,
       "text":"A recap is written after a recording ends."},
      {"page":"features/a.md","page_title":"Alpha","heading":"Recap one","anchor":"r1","level":2,"text":"x"},
      {"page":"features/b.md","page_title":"Beta","heading":"Recap two","anchor":"r2","level":2,"text":"x"},
      {"page":"features/c.md","page_title":"Gamma","heading":"Recap three","anchor":"r3","level":2,"text":"x"},
      {"page":"features/d.md","page_title":"Delta","heading":"Recap four","anchor":"r4","level":2,"text":"x"},
      {"page":"features/e.md","page_title":"Epsilon","heading":"Recap five","anchor":"r5","level":2,"text":"x"}
     ]}
    """

    private let calendar = HelpScreen(rawValue: "calendar", title: "Calendar")

    private func loadedCenter() async -> AskCenter {
        let center = AskCenter(runner: StubGuideRunner(output: Self.fixture))
        await center.loadIfNeeded()
        return center
    }

    func testLoadsIndexOnce() async {
        let runner = StubGuideRunner(output: Self.fixture)
        let center = AskCenter(runner: runner)
        await center.loadIfNeeded()
        await center.loadIfNeeded()
        XCTAssertEqual(runner.recorded, [["guide", "index", "--json"]])
        XCTAssertEqual(center.index?.sections.count, 7)
        XCTAssertNil(center.indexError)
    }

    func testIndexFailureKeepsScreensAndExplains() async {
        let runner = StubGuideRunner(output: nil)
        let center = AskCenter(runner: runner)
        await center.loadIfNeeded()
        XCTAssertNotNil(center.indexError)
        XCTAssertNil(center.index)
        let matches = center.matches(for: "cal", screens: [calendar])
        XCTAssertEqual(matches.screens.map(\.rawValue), ["calendar"])
        XCTAssertTrue(matches.guide.isEmpty)
        // A failure is retried on the next open.
        await center.loadIfNeeded()
        XCTAssertEqual(runner.recorded.count, 2)
    }

    func testMatchesCapAndOrder() async {
        let center = await loadedCenter()
        let screens = [
            HelpScreen(rawValue: "catchUp", title: "Catch Up"),
            HelpScreen(rawValue: "a", title: "Recap Board"),
            HelpScreen(rawValue: "b", title: "My Recaps"),
            HelpScreen(rawValue: "c", title: "Recaps"),
            HelpScreen(rawValue: "d", title: "Old Recap"),
            HelpScreen(rawValue: "e", title: "Recap Log")
        ]
        let matches = center.matches(for: "recap", screens: screens)
        XCTAssertEqual(matches.guide.count, 5)
        XCTAssertEqual(matches.screens.count, 4)
        // Title-prefix matches come before contains matches.
        XCTAssertEqual(matches.screens.map(\.rawValue), ["a", "c", "e", "b"])
    }

    func testHelpSpecIsDraftOnlyMemory() async {
        let center = await loadedCenter()
        let spec = HelpChatSurface.spec(center: center, currentPage: { "Calendar" }, screens: { [self.calendar] })
        XCTAssertEqual(spec.toolAccess, .draftOnly)
        XCTAssertEqual(spec.persistence, .memory)
        XCTAssertNil(spec.key.conversationID)
        XCTAssertEqual(spec.key.contextType, "help")
        XCTAssertTrue(spec.systemPrompt().contains("features/calendar.md — Calendar"))
    }

    /// No tools and no MCP server on any provider (`ai query --no-tools`):
    /// `.draftOnly` alone would still mount the read-only data server.
    func testHelpTurnRunsWithNoTools() async throws {
        let center = await loadedCenter()
        let spec = HelpChatSurface.spec(center: center, currentPage: { "Calendar" }, screens: { [self.calendar] })
        XCTAssertTrue(spec.runOptions().noTools)
        let ai = ScriptedAIService()
        let engine = EmbeddedChatEngine(spec: spec, store: MemoryEmbeddedChatStore(), aiService: ai,
                                        gate: EmbeddedStreamGate(limit: 1))
        engine.send("how do I get a recap")
        for _ in 0..<200 where ai.calls.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let call = try XCTUnwrap(ai.calls.first)
        XCTAssertTrue(call.noTools)
        XCTAssertNil(call.toolMode)
        XCTAssertNil(call.dbPath)
        engine.stop()
    }

    func testTurnPromptCarriesCurrentPageAndSections() async {
        let center = await loadedCenter()
        let spec = HelpChatSurface.spec(center: center, currentPage: { "Calendar" }, screens: { [self.calendar] })
        let prompt = spec.turnPrompt(input("how do I get a recap"))
        XCTAssertTrue(prompt.contains("Current page: Calendar"), prompt)
        XCTAssertTrue(prompt.contains("Get a recap"), prompt)
        XCTAssertTrue(prompt.contains("calendar=Calendar"), prompt)
        // A bare follow-up still finds the topic through the previous question.
        let followUp = spec.turnPrompt(input("and then?"))
        XCTAssertTrue(followUp.contains("Get a recap"), followUp)
    }

    func testPostTurnRecordsSourceAndKeepsReply() async {
        let center = await loadedCenter()
        let spec = HelpChatSurface.spec(center: center, currentPage: { "Calendar" }, screens: { [self.calendar] })
        _ = spec.turnPrompt(input("how do I get a recap"))
        let reply = "Open [Calendar](watchtower-nav://calendar)."
        let result = spec.postTurn(ChatPostTurnInput(reply: reply, turnID: "t1", messageID: 42))
        XCTAssertEqual(result.displayText, reply)
        XCTAssertEqual(center.sources[42]?.heading, "Get a recap")
    }

    /// A provider that resumes no session gets the earlier turns replayed;
    /// a resumed Claude session does not.
    func testFollowUpReplaysEarlierTurnsWhenNotResumed() async {
        let center = await loadedCenter()
        center.history = {
            [
                ChatMessageRecord(id: 1, conversationID: 0, role: "user", text: "how do I get a recap",
                                  createdAt: 1, turnID: "t1"),
                ChatMessageRecord(id: 2, conversationID: 0, role: "assistant", text: "Open the recording's Recap tab.",
                                  createdAt: 2, turnID: "t1"),
                ChatMessageRecord(id: 3, conversationID: 0, role: "user", text: "and then?", createdAt: 3, turnID: "t2")
            ]
        }
        let spec = HelpChatSurface.spec(center: center, currentPage: { "Calendar" }, screens: { [self.calendar] })
        let fresh = spec.turnPrompt(ChatTurnInput(text: "and then?", isResumed: false, previousOwnerMessageAt: nil,
                                                  turnID: "t2"))
        XCTAssertTrue(fresh.contains("Open the recording's Recap tab."), fresh)
        XCTAssertTrue(fresh.contains("Question: and then?"), fresh)
        let resumed = spec.turnPrompt(ChatTurnInput(text: "and then?", isResumed: true, previousOwnerMessageAt: nil,
                                                    turnID: "t2"))
        XCTAssertFalse(resumed.contains("Open the recording's Recap tab."), resumed)
    }

    func testNewConversationForgetsTheLastOne() async {
        let center = await loadedCenter()
        let first = HelpChatSurface.spec(center: center, currentPage: { "Calendar" }, screens: { [] }).key
        _ = HelpChatSurface.spec(center: center, currentPage: { "Calendar" }, screens: { [] })
            .turnPrompt(input("how do I get a recap"))
        center.startConversation()
        let second = HelpChatSurface.spec(center: center, currentPage: { "Calendar" }, screens: { [] })
        XCTAssertNotEqual(first, second.key)
        XCTAssertFalse(second.turnPrompt(input("and then?")).contains("Get a recap"))
    }

    private func input(_ text: String) -> ChatTurnInput {
        ChatTurnInput(text: text, isResumed: false, previousOwnerMessageAt: nil, turnID: UUID().uuidString)
    }
}

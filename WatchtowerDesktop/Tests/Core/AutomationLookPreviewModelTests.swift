import XCTest
@testable import WatchtowerCore

/// The Look step's state table (Inbox builder A, spec "The Look step" →
/// States), from inputs only.
final class AutomationLookPreviewModelTests: XCTestCase {
    private typealias Model = AutomationLookPreviewModel
    private typealias Content = AutomationLookPaneContent
    private typealias Newest = AutomationDraftEntry.Newest

    private static let text = "RECIPE v2"
    private static let blocks = #"{"v":1,"blocks":[{"type":"heading","text":"Waiting for you"}]}"#
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// One `inbox` output with a block document, the way Go writes it.
    private static func inboxOutput(_ title: String, key: String = "") -> String {
        #"{"kind":"inbox","title":"\#(title)","body":"Waiting for you","priority":"high","#
            + #""blocks":\#(blocks),"key":"\#(key)","content_hash":"h-\#(title)"}"#
    }

    private static let manifest = #"{"name":"Waiting","slug":"","trigger_kind":"manual","trigger":"manual","#
        + #""permissions":[],"outputs":["inbox"],"budget_tokens":5000,"budget_minutes":5}"#

    private static func resultJSON(
        status: String,
        outputs: [String] = [],
        tokens: Int = 3100,
        error: String = "",
        steps: String = "[]",
        ok: Bool = true,
        errors: [String] = []
    ) -> String {
        let errorList = errors.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"ok":\#(ok),"errors":[\#(errorList)],"manifest":\#(manifest),"widening":[],"#
            + #""dry_run":{"steps":\#(steps),"outputs":[\#(outputs.joined(separator: ","))],"#
            + #""tokens":\#(tokens),"status":"\#(status)","error":"\#(error)"}}"#
    }

    private static func result(_ json: String) throws -> AutomationDraftEntry.Result {
        try JSONDecoder().decode(AutomationDraftEntry.Result.self, from: Data(json.utf8))
    }

    private static func entryJSON(text: String = text, result: String?, at: String = "2027-01-15T08:00:00Z") -> String {
        let body = result.map { #""result":\#($0)"# } ?? #""result":null,"error":"draft_automation: boom""#
        return #"{"recipe_text":"\#(text)",\#(body),"at":"\#(at)"}"#
    }

    private static func entry(_ json: String) throws -> AutomationDraftEntry {
        try JSONDecoder().decode(AutomationDraftEntry.self, from: Data(json.utf8))
    }

    private func owner(_ json: String, text: String = text, at: Date) throws -> Model.Run {
        Model.Run(text: text, at: at, outcome: .result(try Self.result(json)))
    }

    private func state(
        outputs: [String]? = ["inbox"],
        chat: AutomationDraftEntry? = nil,
        owner: Model.Run? = nil,
        running: Bool = false,
        selected: Int = 0
    ) -> Content {
        Model.state(text: Self.text, outputs: outputs, chatEntry: chat.map { .entry($0) } ?? Newest.none, ownerResult: owner,
                    running: running, selected: selected)
    }

    // MARK: - The table

    func testNoInboxOutput() throws {
        let owner = try owner(Self.resultJSON(status: "succeeded", outputs: [Self.inboxOutput("A")]), at: t0)
        XCTAssertEqual(state(outputs: ["report"], owner: owner), .noInboxOutput)
        XCTAssertEqual(state(outputs: [], owner: owner), .noInboxOutput)
    }

    func testUnknownOutputsDoNotClaimNoInbox() {
        XCTAssertEqual(state(outputs: nil), .empty)
    }

    func testEmptyWithoutAnyRun() {
        XCTAssertEqual(state(), .empty)
        XCTAssertEqual(state(running: true), .running(previous: nil))
    }

    func testPreviewFromOwnerResult() throws {
        let owner = try owner(Self.resultJSON(status: "succeeded",
                                              outputs: [Self.inboxOutput("A", key: "waiting"), Self.inboxOutput("B")]),
                              at: t0)
        guard case let .preview(shown, tokens, at) = state(owner: owner, selected: 1) else {
            return XCTFail("expected a preview, got \(state(owner: owner))")
        }
        XCTAssertEqual(tokens, 3100)
        XCTAssertEqual(at, t0)
        XCTAssertEqual(shown.selected, 1)
        XCTAssertEqual(shown.cards.map(\.title), ["A", "B"])
        XCTAssertEqual(shown.cards[0].key, "waiting")
        XCTAssertEqual(shown.cards[0].priority, "high")
        XCTAssertEqual(shown.cards[0].body, "Waiting for you")
        let decoded = try JSONSerialization.jsonObject(with: Data(shown.cards[0].blocksJSON.utf8)) as? NSDictionary
        let expected = try JSONSerialization.jsonObject(with: Data(Self.blocks.utf8)) as? NSDictionary
        XCTAssertEqual(decoded, expected, "the block document survives the result's decoding")
    }

    func testSelectionIsClamped() throws {
        let owner = try owner(Self.resultJSON(status: "succeeded", outputs: [Self.inboxOutput("A")]), at: t0)
        guard case let .preview(shown, _, _) = state(owner: owner, selected: 9) else { return XCTFail("preview") }
        XCTAssertEqual(shown.selected, 0)
    }

    func testMarkdownCardHasNoBlocks() throws {
        let markdown = #"{"kind":"inbox","title":"M","body":"**hi**","priority":"","blocks":null,"key":"","content_hash":"h"}"#
        let owner = try owner(Self.resultJSON(status: "succeeded", outputs: [markdown]), at: t0)
        guard case let .preview(shown, _, _) = state(owner: owner) else { return XCTFail("preview") }
        XCTAssertEqual(shown.cards, [Content.Card(title: "M", priority: "normal", body: "**hi**")])
    }

    func testZeroOutputsIsNoCard() throws {
        let owner = try owner(Self.resultJSON(status: "succeeded", tokens: 40), at: t0)
        XCTAssertEqual(state(owner: owner), .noCard(tokens: 40))
    }

    func testNonInboxOutputsOnlyIsNoCard() throws {
        let report = #"{"kind":"report","title":"R","body":"x","priority":"","blocks":null,"key":"","content_hash":""}"#
        let owner = try owner(Self.resultJSON(status: "succeeded", outputs: [report], tokens: 7), at: t0)
        XCTAssertEqual(state(owner: owner), .noCard(tokens: 7))
    }

    func testStoppedKeepsCardsMadeBeforeTheStop() throws {
        let owner = try owner(Self.resultJSON(status: "stopped", outputs: [Self.inboxOutput("A")]), at: t0)
        guard case let .stopped(shown) = state(owner: owner) else { return XCTFail("stopped") }
        XCTAssertEqual(shown.cards.map(\.title), ["A"])
        let bare = try self.owner(Self.resultJSON(status: "stopped"), at: t0)
        XCTAssertEqual(state(owner: bare), .stopped(Content.Shown(cards: [])))
    }

    func testRefusedDraftShowsItsRefusalLine() throws {
        let refusal = "this recipe is not confirmed yet"
        let chat = try Self.entry(Self.entryJSON(result: Self.resultJSON(status: "refused", error: refusal)))
        XCTAssertEqual(state(chat: chat), .failed(message: refusal, steps: []))
    }

    func testFailedRunShowsErrorAndLastSteps() throws {
        let steps = (1...7).map {
            #"{"seq":\#($0),"kind":"llm","name":"","status":"ok","args":"","result":"","permission":"","#
                + #""error":"","tokens":10}"#
        }
        let json = Self.resultJSON(status: "failed", error: "output.inbox: blocks[0].type: unknown block type",
                                   steps: "[\(steps.joined(separator: ","))]")
        guard case let .failed(message, lines) = state(owner: try owner(json, at: t0)) else { return XCTFail("failed") }
        XCTAssertEqual(message, "output.inbox: blocks[0].type: unknown block type")
        XCTAssertEqual(lines.count, Model.failedStepLimit)
    }

    func testInvalidRecipeIsFailedWithItsErrors() throws {
        let json = #"{"ok":false,"errors":["line 3: bad trigger"],"manifest":\#(Self.manifest),"widening":[],"dry_run":null}"#
        XCTAssertEqual(state(owner: try owner(json, at: t0)), .failed(message: "line 3: bad trigger", steps: []))
    }

    func testCLIFailureIsFailedNeverEmpty() {
        let run = Model.Run(text: Self.text, at: t0, outcome: .failure("watchtower exited with code 1"))
        XCTAssertEqual(state(owner: run), .failed(message: "watchtower exited with code 1", steps: []))
    }

    func testChatEntryWithErrorIsFailed() throws {
        let chat = try Self.entry(Self.entryJSON(result: nil))
        XCTAssertEqual(state(chat: chat), .failed(message: "Couldn't check this draft: draft_automation: boom", steps: []))
    }

    // MARK: - Two producers

    func testNewestOfChatAndOwnerWinsForTheSameText() throws {
        let chatResult = Self.resultJSON(status: "succeeded", outputs: [Self.inboxOutput("Chat")])
        let chat = try Self.entry(Self.entryJSON(result: chatResult))
        let chatAt = try XCTUnwrap(chat.at)
        let olderOwner = try owner(Self.resultJSON(status: "succeeded", outputs: [Self.inboxOutput("Owner")]),
                                   at: chatAt.addingTimeInterval(-60))
        let newerOwner = try owner(Self.resultJSON(status: "succeeded", outputs: [Self.inboxOutput("Owner")]),
                                   at: chatAt.addingTimeInterval(60))
        guard case let .preview(fromChat, _, _) = state(chat: chat, owner: olderOwner),
              case let .preview(fromOwner, _, _) = state(chat: chat, owner: newerOwner) else {
            return XCTFail("previews")
        }
        XCTAssertEqual(fromChat.cards.map(\.title), ["Chat"])
        XCTAssertEqual(fromOwner.cards.map(\.title), ["Owner"])
    }

    func testRunOfOtherBytesIsStale() throws {
        let other = try owner(Self.resultJSON(status: "succeeded", outputs: [Self.inboxOutput("Old")]),
                              text: "RECIPE v1", at: t0)
        guard case let .stale(shown) = state(owner: other) else { return XCTFail("stale") }
        XCTAssertEqual(shown.cards.map(\.title), ["Old"])
        XCTAssertFalse(shown.cards[0].blocksJSON.isEmpty)
        let chat = try Self.entry(Self.entryJSON(text: "RECIPE v1",
                                                 result: Self.resultJSON(status: "succeeded",
                                                                         outputs: [Self.inboxOutput("Old")])))
        guard case .stale = state(chat: chat) else { return XCTFail("a chat entry for other bytes is stale") }
    }

    func testRunOfOtherBytesWithoutCardsIsEmpty() throws {
        let other = try owner(Self.resultJSON(status: "failed", error: "x"), text: "RECIPE v1", at: t0)
        XCTAssertEqual(state(owner: other), .empty)
    }

    func testOlderRunOfThisTextWinsOverNewerRunOfOtherBytes() throws {
        let thisResult = Self.resultJSON(status: "succeeded", outputs: [Self.inboxOutput("This")])
        let chat = try Self.entry(Self.entryJSON(result: thisResult))
        let other = try owner(Self.resultJSON(status: "succeeded", outputs: [Self.inboxOutput("Other")]),
                              text: "RECIPE v1", at: try XCTUnwrap(chat.at).addingTimeInterval(60))
        guard case let .preview(shown, _, _) = state(chat: chat, owner: other) else { return XCTFail("preview") }
        XCTAssertEqual(shown.cards.map(\.title), ["This"])
    }

    func testRunningDimsThePreviousCards() throws {
        let owner = try owner(Self.resultJSON(status: "succeeded", outputs: [Self.inboxOutput("A")]), at: t0)
        guard case let .running(previous) = state(owner: owner, running: true) else { return XCTFail("running") }
        XCTAssertEqual(previous?.cards.map(\.title), ["A"])
        let failed = Model.Run(text: Self.text, at: t0, outcome: .failure("x"))
        XCTAssertEqual(state(owner: failed, running: true), .running(previous: nil))
    }

    func testChatEntryPicksThisTextElseTheNewest() throws {
        let entries = [
            Self.entryJSON(text: Self.text, result: Self.resultJSON(status: "succeeded")),
            Self.entryJSON(text: "RECIPE v3", result: Self.resultJSON(status: "succeeded")),
            "not json"
        ]
        XCTAssertEqual(Model.chatEntry(in: entries, text: Self.text), .undecodable,
                       "an unreadable newest entry is never replaced by an older one")
        let readable = Array(entries.dropLast()) + [entries[1]]
        guard case let .entry(this) = Model.chatEntry(in: ["not json"] + readable, text: Self.text),
              case let .entry(other) = Model.chatEntry(in: readable, text: "RECIPE v9") else {
            return XCTFail("readable newest entries")
        }
        XCTAssertEqual(this.recipeText, Self.text, "an older unreadable entry is passed over")
        XCTAssertEqual(other.recipeText, "RECIPE v3")
        XCTAssertEqual(Model.chatEntry(in: [], text: Self.text), Newest.none)
    }

    /// The newest cache entry does not decode: the pane says so instead of
    /// showing an older entry's cards as the current preview.
    func testUnreadableNewestEntryIsAnErrorNotAnOlderPreview() throws {
        let entries = [
            Self.entryJSON(result: Self.resultJSON(status: "succeeded", outputs: [Self.inboxOutput("Old")])),
            #"{"recipe_text":"RECIPE v2","result":"#
        ]
        let chat = Model.chatEntry(in: entries, text: Self.text)
        let pane = Model.state(text: Self.text, outputs: ["inbox"], chatEntry: chat, ownerResult: nil, running: false)
        XCTAssertEqual(pane, .failed(message: Model.unreadableChatLine, steps: []))
        let owner = try owner(Self.resultJSON(status: "succeeded", outputs: [Self.inboxOutput("Mine")]), at: t0)
        guard case let .preview(shown, _, _) = Model.state(text: Self.text, outputs: ["inbox"], chatEntry: chat,
                                                           ownerResult: owner, running: false) else {
            return XCTFail("the owner's own Dry run of this text is still shown")
        }
        XCTAssertEqual(shown.cards.map(\.title), ["Mine"])
    }

    /// The only cache entry does not decode: an error, never `.empty`.
    func testOnlyEntryUnreadableIsAnErrorNotEmpty() {
        let chat = Model.chatEntry(in: ["not json"], text: Self.text)
        XCTAssertEqual(chat, .undecodable)
        XCTAssertEqual(Model.state(text: Self.text, outputs: ["inbox"], chatEntry: chat, ownerResult: nil, running: false),
                       .failed(message: Model.unreadableChatLine, steps: []))
        XCTAssertEqual(Model.state(text: Self.text, outputs: ["inbox"], chatEntry: chat, ownerResult: nil, running: true),
                       .running(previous: nil))
    }

    func testEntryWithoutTimeIsOlderThanAnyOwnerRun() throws {
        let json = #"{"recipe_text":"RECIPE v2","result":\#(Self.resultJSON(status: "succeeded", outputs: [Self.inboxOutput("Chat")]))}"#
        let chat = try Self.entry(json)
        XCTAssertNil(chat.at)
        let owner = try owner(Self.resultJSON(status: "succeeded", outputs: [Self.inboxOutput("Owner")]),
                              at: Date(timeIntervalSince1970: 0))
        guard case let .preview(shown, _, _) = state(chat: chat, owner: owner) else { return XCTFail("preview") }
        XCTAssertEqual(shown.cards.map(\.title), ["Owner"])
    }

    /// A cache entry an older CLI wrote has no `outputs` in its dry run: it
    /// still decodes (the Draft panel keeps showing it), with no cards.
    func testOlderEntryWithoutOutputsStillDecodes() throws {
        let json = #"{"recipe_text":"RECIPE v2","result":{"ok":true,"errors":[],"manifest":\#(Self.manifest),"#
            + #""dry_run":{"steps":[],"tokens":9,"status":"succeeded","error":""}},"at":"2027-01-15T08:00:00Z"}"#
        let chat = try Self.entry(json)
        XCTAssertEqual(chat.result?.dryRun?.outputs, [])
        XCTAssertEqual(state(chat: chat), .noCard(tokens: 9))
    }

    /// The card's own buttons reach the pane in the stored form, so the
    /// preview draws them as the Inbox will; none (or an older CLI) is "[]".
    func testCardActionsReachThePane() throws {
        let withActions = #"{"kind":"inbox","title":"A","body":"b","priority":"normal","blocks":null,"key":"","#
            + #""content_hash":"h","actions":[{"label":"Ask","kind":"chat","chat":"why?","primary":true}]}"#
        let older = #"{"kind":"inbox","title":"B","body":"b","priority":"normal","blocks":null,"key":"","content_hash":"h"}"#
        let owner = try owner(Self.resultJSON(status: "succeeded", outputs: [withActions, older]), at: t0)
        guard case let .preview(shown, _, _) = state(owner: owner) else { return XCTFail("preview") }
        let actions = try JSONSerialization.jsonObject(with: Data(shown.cards[0].actionsJSON.utf8)) as? [[String: Any]]
        XCTAssertEqual(actions?.count, 1)
        XCTAssertEqual(actions?.first?["label"] as? String, "Ask")
        XCTAssertEqual(actions?.first?["chat"] as? String, "why?")
        XCTAssertEqual(shown.cards[1].actionsJSON, "[]")
    }
}

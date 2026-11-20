import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// Ask answers from the phone (spec §4.6, §5.2, §6.2, §9, §13 B4): the
/// question, review and check forms, validation that mirrors the Mac's,
/// the answer through the real outbox, its echoes, and a superseded ask
/// (Review Focus 3).
@MainActor
final class AskFormTests: XCTestCase {
    private let now = Date()

    private struct Fixture {
        let store: ReplicaStore
        let outbox: ActionOutbox
        let drafts: AskDraftStore
        let answerer: AskAnswerer
        let starter: SessionStarter
    }

    private func makeFixture() async throws -> Fixture {
        let store = try TestPhone.replica()
        let outbox = ActionOutbox(transport: try TestPhone.transport(), store: store, deviceID: DemoSeed.device.deviceID)
        let drafts = AskDraftStore()
        let answerer = AskAnswerer.sending(through: outbox, store: store, drafts: drafts)
        let starter = SessionStarter.sending(through: outbox, store: store)
        await outbox.setAppliedObserver(HubSession.appliedObserver(askAnswerer: answerer, sessionStarts: starter))
        return Fixture(store: store, outbox: outbox, drafts: drafts, answerer: answerer, starter: starter)
    }

    private func makeAsk(_ id: Int64, _ overrides: [String: Any]) throws -> OwnerAsk {
        try mirror(OwnerAsk.self, DemoSeed.JSON.ask(id, workbench: DemoSeed.acmeID, overrides))
    }

    private func replica(_ asks: [OwnerAsk], store: ReplicaStore? = nil, heartbeatAge: TimeInterval = 10) throws -> WorkbenchReplicaSnapshot {
        var snapshot = WorkbenchReplicaSnapshot()
        snapshot.asks = asks
        snapshot.pending = try store?.pendingActions() ?? []
        let at = now.addingTimeInterval(-heartbeatAge)
        snapshot.heartbeat = HeartbeatPayload(
            updatedAt: at, appVersion: "1.0", hubID: "hub", macName: "Acme Mac", flavor: .default,
            lastPublishAt: at, lastRelayAt: at, relayBacklog: 0, accounts: [],
            enabledAt: at, ownerUser: "_user", sharing: .none
        )
        return snapshot
    }

    private func formOf(_ model: AskViewModel, _ snapshot: WorkbenchReplicaSnapshot) throws -> AskFormModel {
        try XCTUnwrap(model.form(snapshot: snapshot, now: now))
    }

    /// Rewrites the only overlay row as the Mac's echo.
    private func echo(
        _ fixture: Fixture,
        _ status: ActionStatus,
        reason: ActionReason? = nil,
        result: [String: JSONValue]? = nil,
        message: String? = nil
    ) async throws {
        var echo = try XCTUnwrap(fixture.store.pendingActions().first).action
        echo.status = status
        echo.reason = reason
        echo.result = result
        echo.errorMessage = message
        try await fixture.outbox.applyEcho(echo)
    }

    private static let twoQuestions: [String: Any] = [
        "kind": "question", "title": "Two questions",
        "payload": ["questions": [
            ["id": "lanes", "question": "Lanes per group?", "options": [
                ["label": "Yes", "recommended": true], ["label": "No"]
            ]],
            ["id": "fold", "question": "Which folds?", "multi": true, "options": [
                ["label": "Done"], ["label": "Dismissed"], ["label": "Blocked"]
            ]]
        ]]
    ]

    private static let review: [String: Any] = [
        "kind": "review", "title": "Review the plan", "doc_path": "docs/plan.md",
        "doc_snapshot": "# Plan\n\nShip behind a flag for acme.\n", "payload": ["focus": [["text": "The rollout"]]]
    ]

    // MARK: - Questions

    func testMultiQuestionPagingKeepsAnswersAcrossPages() async throws {
        let fixture = try await makeFixture()
        let ask = try makeAsk(120, Self.twoQuestions)
        let snapshot = try replica([ask])
        let model = AskViewModel(askID: 120, drafts: fixture.drafts, answerer: fixture.answerer)

        var page = try XCTUnwrap(try formOf(model, snapshot).question)
        let first = try formOf(model, snapshot)
        XCTAssertEqual(first.kindIcon, "questionmark.bubble")
        XCTAssertEqual(first.kindName, "Question")
        XCTAssertEqual(first.idText, "#120")
        XCTAssertEqual(first.pageText, "1 of 2", "words, not codes (design pass A1)")
        XCTAssertEqual(page.options.map(\.recommended), [true, false])
        model.pick("Yes", in: page)
        model.next(of: page.count)

        page = try XCTUnwrap(try formOf(model, snapshot).question)
        XCTAssertEqual(page.questionID, "fold")
        XCTAssertTrue(page.isLast)
        XCTAssertFalse(try formOf(model, snapshot).canSend, "the second question has no answer yet")
        model.pick("Done", in: page)
        model.pick("Blocked", in: page)
        model.previous()

        page = try XCTUnwrap(try formOf(model, snapshot).question)
        XCTAssertEqual(page.options.filter(\.isPicked).map(\.label), ["Yes"], "the first page kept its pick")
        model.next(of: page.count)
        XCTAssertEqual(try XCTUnwrap(try formOf(model, snapshot).question).options.filter(\.isPicked).map(\.label), ["Done", "Blocked"])
        XCTAssertTrue(try formOf(model, snapshot).canSend)

        // A fresh screen on the same ask (navigation away and back) keeps it.
        let reopened = AskViewModel(askID: 120, drafts: fixture.drafts, answerer: fixture.answerer)
        XCTAssertEqual(try XCTUnwrap(try formOf(reopened, snapshot).question).options.filter(\.isPicked).map(\.label), ["Yes"])
        XCTAssertTrue(try formOf(reopened, snapshot).canSend)
    }

    /// Design pass A1: the header is the kind's icon and word, "#id" and the
    /// page; orange while open, secondary once closed. A single question has
    /// no page text.
    func testTheHeaderNamesTheKindTheIDAndThePage() async throws {
        let fixture = try await makeFixture()
        let demo = try demoSnapshot(now: now)
        func form(_ id: Int64) throws -> AskFormModel {
            try XCTUnwrap(AskViewModel(askID: id, drafts: fixture.drafts, answerer: fixture.answerer).form(snapshot: demo, now: now))
        }
        let review = try form(110)
        XCTAssertEqual([review.kindIcon, review.kindName, review.idText], ["doc.text.magnifyingglass", "Review", "#110"])
        XCTAssertNil(review.pageText)
        XCTAssertEqual(review.headerTone, .waitingForYou)
        let check = try form(111)
        XCTAssertEqual([check.kindIcon, check.kindName], ["checklist", "Check"])
        let closed = try form(105)
        XCTAssertEqual(closed.headerTone, .secondary, "a closed ask's header is not waiting for you")
        XCTAssertNil(closed.pageText, "a closed ask shows no question pages")

        let single = try makeAsk(121, [
            "kind": "question", "payload": ["questions": [["id": "q", "question": "Keep it?", "options": [["label": "Yes"], ["label": "No"]]]]]
        ])
        let model = AskViewModel(askID: 121, drafts: fixture.drafts, answerer: fixture.answerer)
        XCTAssertNil(try formOf(model, try replica([single])).pageText, "one question has no page text")
    }

    // MARK: - Where the ask came from (#1786)

    func testTheSourceLinksOpenOnlyWhatThePhoneHas() async throws {
        let fixture = try await makeFixture()
        var demo = try demoSnapshot(now: now)
        demo.asks += [
            // An external terminal's ask on an archived target.
            try makeAsk(130, ["target_id": 417]),
            // Its session deleted since, its target too.
            try makeAsk(131, ["session_id": 99, "target_id": 999]),
            try makeAsk(132, [:])
        ]
        func form(_ id: Int64) throws -> AskFormModel {
            try XCTUnwrap(AskViewModel(askID: id, drafts: fixture.drafts, answerer: fixture.answerer).form(snapshot: demo, now: now))
        }
        typealias Link = AskFormModel.SourceLink
        let both = try form(109)
        XCTAssertEqual(both.subline, "From Acme · Archive closed targets", "the task number moves into its link")
        XCTAssertEqual(both.sourceLinks.map(\.destination), [.session(11), .target(415)])
        XCTAssertEqual(both.sourceLinks.map(\.title), ["Open session", "Task #415"])
        let sessionOnly = try form(106)
        XCTAssertEqual(sessionOnly.sourceLinks.map(\.destination), [Link.Destination.session(11)])
        let archived = try form(130)
        XCTAssertEqual(archived.subline, "From Acme")
        XCTAssertEqual(archived.sourceLinks.map(\.destination), [Link.Destination.target(417)], "an archived target keeps its link")
        let gone = try form(131)
        XCTAssertEqual(gone.subline, "From Acme · #999", "a target not on the phone keeps its number as text")
        XCTAssertTrue(gone.sourceLinks.isEmpty, "no link to a session or target the phone does not have")
        XCTAssertTrue(try form(132).sourceLinks.isEmpty)
        let closed = try form(105)
        XCTAssertEqual(closed.sourceLinks.map(\.destination), [.session(11), .target(415)], "a closed ask links too")
        let withdrawn = try form(107)
        XCTAssertEqual(withdrawn.sourceLinks.map(\.destination), [.session(14), .target(431)])
    }

    private func chat(_ session: Int64, agentID: String? = nil, _ entries: [[String: Any]]) throws -> SessionChat {
        var json: [String: Any] = ["session_id": session, "live": true, "entries_more": 0, "entries": entries]
        if let agentID { json["agent_id"] = agentID }
        return try mirror(SessionChat.self, json)
    }

    /// `asOf` nil: the record's stamp is unknown; the chat must prove itself.
    private func agentContext(_ ask: OwnerAsk, chat: SessionChat?, asOf: Date? = nil) throws -> AskFormModel.AgentContext? {
        try XCTUnwrap(AskFormModel(
            askID: ask.id, snapshot: try replica([ask]), draft: AskDraft(), page: 0, now: now,
            applied: nil, isSending: false, chat: chat, chatAsOf: asOf
        )).agentContext
    }

    func testAChatThatStopsBeforeTheAskShowsNoMessage() throws {
        let asked = now.addingTimeInterval(-600)
        let ask = try makeAsk(143, ["session_id": 11, "created_at": DemoSeed.JSON.stamp(asked)])
        let stale = try chat(11, [
            ["id": "a", "kind": "agent", "at": DemoSeed.JSON.stamp(asked.addingTimeInterval(-900)), "text": "An older watch's last line."]
        ])
        XCTAssertNil(try agentContext(ask, chat: stale), "no stamp, nothing at or after the ask: maybe stale")
        XCTAssertNil(try agentContext(ask, chat: stale, asOf: asked.addingTimeInterval(-1)), "written before the ask")
        XCTAssertEqual(
            try agentContext(ask, chat: stale, asOf: asked)?.text, "An older watch's last line.",
            "written at the ask: it has everything before it"
        )
        XCTAssertNotNil(try agentContext(ask, chat: stale, asOf: now))
    }

    func testTheBoundariesOfTheAgentMessage() throws {
        let asked = now.addingTimeInterval(-600)
        let ask = try makeAsk(144, ["session_id": 11, "created_at": DemoSeed.JSON.stamp(asked)])
        let at = DemoSeed.JSON.stamp(asked)
        let before = DemoSeed.JSON.stamp(asked.addingTimeInterval(-60))
        let exact = try chat(11, [
            ["id": "a", "kind": "agent", "at": before, "text": "Earlier."],
            ["id": "b", "kind": "agent", "at": at, "text": "Written at the ask."]
        ])
        XCTAssertEqual(try agentContext(ask, chat: exact)?.text, "Written at the ask.", "an entry at the ask counts and covers it")
        let tied = try chat(11, [
            ["id": "a", "kind": "agent", "at": before, "text": "First of two."],
            ["id": "b", "kind": "agent", "at": before, "text": "Second of two."]
        ])
        XCTAssertEqual(try agentContext(ask, chat: tied, asOf: now)?.text, "Second of two.", "equal stamps: the later in the feed")

        func folds(_ text: String) throws -> Bool {
            try XCTUnwrap(try agentContext(ask, chat: try chat(11, [["id": "a", "kind": "agent", "at": before, "text": text]]), asOf: now)).isLong
        }
        XCTAssertFalse(try folds(String(repeating: "a", count: 280)), "280 characters fit")
        XCTAssertTrue(try folds(String(repeating: "a", count: 281)))
        XCTAssertFalse(try folds("1\n2\n3\n4\n5"), "five lines fit")
        XCTAssertTrue(try folds("1\n2\n3\n4\n5\n6"))
    }

    func testOpenedFromItsOwnSessionTheFormHidesOpenSession() async throws {
        let fixture = try await makeFixture()
        let demo = try demoSnapshot(now: now)
        let fromSession = AskViewModel(askID: 109, drafts: fixture.drafts, answerer: fixture.answerer, openedFromSessionID: 11)
        let form = try formOf(fromSession, demo)
        XCTAssertEqual(form.sourceLinks.map(\.destination), [.target(415)], "Back is the way to the session")
        XCTAssertEqual(form.subline, "From Acme · Archive closed targets", "the line still names the session")
        let elsewhere = AskViewModel(askID: 109, drafts: fixture.drafts, answerer: fixture.answerer, openedFromSessionID: 14)
        XCTAssertEqual(try formOf(elsewhere, demo).sourceLinks.map(\.destination), [.session(11), .target(415)])
    }

    func testTheAgentContextIsTheLastAgentMessageAtOrBeforeTheAsk() throws {
        let asked = now.addingTimeInterval(-600)
        let ask = try makeAsk(140, ["session_id": 11, "created_at": DemoSeed.JSON.stamp(asked)])
        let stamp: (TimeInterval) -> Int = { DemoSeed.JSON.stamp(asked.addingTimeInterval($0)) }
        let entries: [[String: Any]] = [
            ["id": "a", "kind": "agent", "at": stamp(-300), "text": "Older reasoning."],
            ["id": "b", "kind": "agent", "at": stamp(-60), "text": "  Two wordings fit; I'll ask.  "],
            ["id": "c", "kind": "owner", "at": stamp(-30), "text": "An owner line is not the agent's."],
            ["id": "d", "kind": "agent", "at": stamp(-20), "text": "   "],
            ["id": "e", "kind": "agent", "text": "Undated: cannot be placed."],
            ["id": "f", "kind": "agent", "at": stamp(120), "text": "After the ask."]
        ]
        let context = try XCTUnwrap(try agentContext(ask, chat: try chat(11, entries)))
        XCTAssertEqual(context.label, "Agent, before asking")
        XCTAssertEqual(context.text, "Two wordings fit; I'll ask.")
        XCTAssertFalse(context.isLong)

        XCTAssertNil(try agentContext(ask, chat: nil), "no chat on the phone: nothing, nothing asked for")
        XCTAssertNil(try agentContext(ask, chat: try chat(12, entries)), "another session's chat")
        XCTAssertNil(try agentContext(ask, chat: try chat(11, agentID: "sub-1", entries)), "a subagent's chat")
        XCTAssertNil(try agentContext(ask, chat: try chat(11, [entries[5]])), "only messages after the ask")
        let external = try makeAsk(141, ["created_at": DemoSeed.JSON.stamp(asked)])
        XCTAssertNil(try agentContext(external, chat: try chat(11, entries)), "an ask without a session has no chat")
    }

    func testALongOrClippedAgentMessageFolds() throws {
        let ask = try makeAsk(142, ["session_id": 11, "created_at": DemoSeed.JSON.stamp(now.addingTimeInterval(-60))])
        let before = DemoSeed.JSON.stamp(now.addingTimeInterval(-120))
        let long = String(repeating: "word ", count: 80)
        let clipped = try XCTUnwrap(try agentContext(ask, chat: try chat(11, [
            ["id": "a", "kind": "agent", "at": before, "text": long, "text_clipped": true]
        ]), asOf: now))
        XCTAssertTrue(clipped.text.hasSuffix("word…"), "a clipped text says so")
        XCTAssertTrue(clipped.isLong)
        let lines = try XCTUnwrap(try agentContext(ask, chat: try chat(11, [
            ["id": "a", "kind": "agent", "at": before, "text": "1\n2\n3\n4\n5\n6"]
        ]), asOf: now))
        XCTAssertTrue(lines.isLong, "six short lines fold too")
        XCTAssertEqual([AskText.showMore, AskText.showLess], ["Show more", "Show less"])
    }

    func testTheScreenReadsAChatAlreadyOnThePhoneAndAsksTheMacForNothing() async throws {
        let fixture = try await makeFixture()
        let store = try makePoolStore(.demo)
        let transport = InMemoryCloudTransport()
        try await DemoSeed.load(into: TestPhone.hub(over: transport, .demo), now: now)
        _ = try await ReplicaHydrator(transport: transport, store: store).hydrateOnce()
        let demo = try demoSnapshot(now: now)
        let model = AskViewModel(askID: 109, drafts: fixture.drafts, answerer: fixture.answerer)
        XCTAssertNil(try formOf(model, demo).agentContext, "nothing before the chat is read")

        model.observeChat(sessionID: 11, store: store)
        try await poll({ model.chat != nil }, "the demo chat never arrived")
        XCTAssertEqual(model.chatAsOf.map { Int($0.timeIntervalSince1970) }, Int(now.timeIntervalSince1970), "the hub's own stamp")
        XCTAssertEqual(try formOf(model, demo).agentContext?.text, "On it. I will add the menu item and an undo.")
        XCTAssertTrue(try store.pendingActions().isEmpty, "no session_chat_request: the ask screen only reads")

        model.stopObservingChat()
        XCTAssertNotNil(model.chat, "leaving for the session keeps the text for the way back")
        model.observeChat(sessionID: 14, store: store)
        XCTAssertNil(model.chat, "another session drops the old chat at once")
        model.stopObservingChat()
    }

    func testAPickOnASingleSelectQuestionReplacesTheOtherAndTogglesOff() async throws {
        let fixture = try await makeFixture()
        let snapshot = try replica([try makeAsk(120, Self.twoQuestions)])
        let model = AskViewModel(askID: 120, drafts: fixture.drafts, answerer: fixture.answerer)
        let page = try XCTUnwrap(try formOf(model, snapshot).question)
        model.pick("Yes", in: page)
        model.pick("No", in: page)
        XCTAssertEqual(model.draft.picks["lanes"]?.labels, ["No"])
        model.pick("No", in: page)
        XCTAssertEqual(model.draft.picks["lanes"]?.labels, [])
    }

    func testOtherWithOnlyWhitespaceIsNoAnswer() async throws {
        let fixture = try await makeFixture()
        let ask = try makeAsk(121, [
            "kind": "question", "payload": ["questions": [["id": "q", "question": "Which?", "options": [["label": "A"], ["label": "B"]]]]]
        ])
        let snapshot = try replica([ask])
        let model = AskViewModel(askID: 121, drafts: fixture.drafts, answerer: fixture.answerer)

        model.setOther("  \n\t ", for: "q")
        XCTAssertFalse(try formOf(model, snapshot).canSend)
        try await fixture.answerer.send(ask)
        XCTAssertTrue(try fixture.store.pendingActions().isEmpty, "a draft the tower would refuse is never sent")

        model.setOther("  Neither, use C  ", for: "q")
        XCTAssertTrue(try formOf(model, snapshot).canSend)
        await model.send(ask)
        let row = try XCTUnwrap(try fixture.store.pendingActions().first)
        XCTAssertEqual(row.action.kind, .askAnswer)
        XCTAssertEqual(row.entityRecordName, "owner_ask-121")
        XCTAssertEqual(row.action.entityID, "121")
        let params = try AskAnswerParams(wireParams: row.action.params)
        XCTAssertEqual(params, AskAnswerParams(
            workbenchID: DemoSeed.acmeID,
            answer: OwnerAskAnswer(answers: [.init(id: "q", other: "Neither, use C")])
        ))
    }

    func testALabelNotAmongTheOptionsIsNoAnswer() async throws {
        let fixture = try await makeFixture()
        let ask = try makeAsk(121, [
            "kind": "question", "payload": ["questions": [["id": "q", "question": "Which?", "options": [["label": "A"], ["label": "B"]]]]]
        ])
        fixture.drafts.update(121) { $0.picks["q"] = AskQuestionPick(labels: ["Z"]) }
        XCTAssertFalse(fixture.drafts.draft(for: 121).isAnswerable(for: ask))
        fixture.drafts.update(121) { $0.picks["q"] = AskQuestionPick(labels: ["A", "B"]) }
        XCTAssertFalse(fixture.drafts.draft(for: 121).isAnswerable(for: ask), "single select takes one label")
    }

    // MARK: - Review

    func testAClippedSnapshotShowsHowMuchIsShown() async throws {
        let fixture = try await makeFixture()
        var json = Self.review
        json["doc_clipped"] = true
        json["doc_bytes"] = 2_097_152
        let snapshot = try replica([try makeAsk(130, json)])
        let model = AskViewModel(askID: 130, drafts: fixture.drafts, answerer: fixture.answerer)

        let review = try XCTUnwrap(try formOf(model, snapshot).review)
        // N in the phone's locale ("2.1 MB", "2,1 MB").
        let full = ByteCountFormatter.string(fromByteCount: 2_097_152, countStyle: .file)
        XCTAssertEqual(review.clippedNotice, "Showing the first 256 KB of \(full) — the rest is only on the tower")
        XCTAssertEqual(
            review.clippedEnd, "The phone has only the first 256 KB of docs/plan.md. Open the ask on the tower to read the rest.",
            "where the text stops, what is missing and where it is"
        )
        XCTAssertEqual(review.document?.text, "Plan\n\nShip behind a flag for acme.\n\n")
        XCTAssertEqual(review.paragraphs.map(\.text), ["Plan", "Ship behind a flag for acme."])

        let whole = try XCTUnwrap(try formOf(model, try replica([try makeAsk(130, Self.review)])).review)
        XCTAssertNil(whole.clippedNotice)
        XCTAssertNil(whole.clippedEnd)
    }

    /// #1787: a comment shows under the paragraph it was made on; one whose
    /// quote is no longer at its place (a revised snapshot) goes after the
    /// document. No snapshot: no paragraphs, the count alone.
    func testACommentSitsUnderItsParagraph() async throws {
        let fixture = try await makeFixture()
        let snapshot = try replica([try makeAsk(130, Self.review)])
        let model = AskViewModel(askID: 130, drafts: fixture.drafts, answerer: fixture.answerer)
        let review = try XCTUnwrap(try formOf(model, snapshot).review)
        let document = try XCTUnwrap(review.document)
        let body = try XCTUnwrap(review.paragraphs.last)
        XCTAssertEqual(review.commentsLine, "Press and hold a paragraph to comment · 0 comments")

        let id = try XCTUnwrap(model.addComment(on: body.range, in: document, body: "Which flag?"))
        let placed = try XCTUnwrap(try formOf(model, snapshot).review)
        XCTAssertEqual(placed.commentsByParagraph[body.id]?.map(\.id), [id])
        XCTAssertEqual(placed.unplacedComments, [])
        XCTAssertEqual(placed.commentsLine, "Press and hold a paragraph to comment · 1 comment")

        var revised = Self.review
        revised["doc_snapshot"] = "# Plan\n\nA new first line.\n\nShip behind a flag for acme.\n"
        let moved = try XCTUnwrap(try formOf(model, try replica([try makeAsk(130, revised)])).review)
        XCTAssertEqual(moved.unplacedComments.map(\.id), [id], "the quote moved: drawn after the document")

        var bare = Self.review
        bare["doc_snapshot"] = nil
        let none = try XCTUnwrap(try formOf(model, try replica([try makeAsk(130, bare)])).review)
        XCTAssertEqual(none.paragraphs, [])
        XCTAssertEqual(none.commentsLine, "1 comment")
    }

    /// #1787: the draft keeps a comment's location across leaving and
    /// reopening the ask (a new screen model on the same store), so it is
    /// still drawn under its paragraph.
    func testACommentsLocationSurvivesReopeningTheAsk() async throws {
        let fixture = try await makeFixture()
        let snapshot = try replica([try makeAsk(130, Self.review)])
        let first = AskViewModel(askID: 130, drafts: fixture.drafts, answerer: fixture.answerer)
        let review = try XCTUnwrap(try formOf(first, snapshot).review)
        let body = try XCTUnwrap(review.paragraphs.last)
        let id = try XCTUnwrap(first.addComment(on: NSRange(location: body.range.location, length: 4), in: try XCTUnwrap(review.document), body: "x"))

        let reopened = AskViewModel(askID: 130, drafts: fixture.drafts, answerer: fixture.answerer)
        XCTAssertEqual(reopened.draft.comments.first?.location, body.range.location)
        XCTAssertEqual(try formOf(reopened, snapshot).review?.commentsByParagraph[body.id]?.map(\.id), [id])
    }

    /// #1787: comments are placed by location and checked by quote: two
    /// comments starting at the same place with different quotes ("Ship",
    /// the whole line) both sit under that paragraph; one whose quote is not
    /// the text at its location (made on another snapshot) is drawn after
    /// the document instead of under a wrong paragraph.
    func testCommentsAtOneLocationArePlacedByTheirQuote() async throws {
        let fixture = try await makeFixture()
        let snapshot = try replica([try makeAsk(130, Self.review)])
        let model = AskViewModel(askID: 130, drafts: fixture.drafts, answerer: fixture.answerer)
        let review = try XCTUnwrap(try formOf(model, snapshot).review)
        let document = try XCTUnwrap(review.document)
        let body = try XCTUnwrap(review.paragraphs.last)
        let word = try XCTUnwrap(model.addComment(on: NSRange(location: body.range.location, length: 4), in: document, body: "a"))
        let line = try XCTUnwrap(model.addComment(on: body.range, in: document, body: "b"))
        let elsewhere = PlainTextRendering.render("# Plan\n\nAnother text here.\n")
        let stale = try XCTUnwrap(CommentAnchorBuilder.anchor(selection: NSRange(location: body.range.location, length: 7), in: elsewhere))
        let staleID = UUID()
        fixture.drafts.update(130) { $0.comments.append(AskCommentDraft(id: staleID, anchor: stale, body: "c", location: body.range.location)) }

        let placed = try XCTUnwrap(try formOf(model, snapshot).review)
        XCTAssertEqual(placed.commentsByParagraph[body.id]?.map(\.id), [word, line])
        XCTAssertEqual(placed.unplacedComments.map(\.id), [staleID])
    }

    /// #1787 review: the paragraphs follow the rendered document, not just
    /// its text — a heading level change keeps the text and changes the split.
    func testAHeadingLevelChangeSplitsAgain() async throws {
        let fixture = try await makeFixture()
        let model = AskViewModel(askID: 130, drafts: fixture.drafts, answerer: fixture.answerer)
        let first = try XCTUnwrap(try formOf(model, try replica([try makeAsk(130, Self.review)])).review)
        XCTAssertEqual(first.paragraphs.first?.headingLevel, 1)

        var revised = Self.review
        revised["doc_snapshot"] = "## Plan\n\nShip behind a flag for acme.\n"
        let second = try XCTUnwrap(try formOf(model, try replica([try makeAsk(130, revised)])).review)
        XCTAssertEqual(second.document?.text, first.document?.text, "same text")
        XCTAssertEqual(second.paragraphs.first?.headingLevel, 2)
    }

    /// #1787: Request changes needs words — a note or a comment with text;
    /// Approve does not. The answer sent is the same shape as before.
    func testRequestChangesNeedsANoteOrAComment() async throws {
        let fixture = try await makeFixture()
        let ask = try makeAsk(130, Self.review)
        let snapshot = try replica([ask])
        let model = AskViewModel(askID: 130, drafts: fixture.drafts, answerer: fixture.answerer)
        var form = try formOf(model, snapshot)
        XCTAssertTrue(form.canSendVerdict)
        XCTAssertFalse(form.canRequestChanges)
        XCTAssertEqual(form.requestChangesHint, "Add a comment or a note to request changes")

        let document = try XCTUnwrap(form.review?.document)
        let id = try XCTUnwrap(model.addComment(on: NSRange(location: 6, length: 4), in: document, body: "  "))
        XCTAssertFalse(try formOf(model, snapshot).canRequestChanges, "a blank comment says nothing")
        model.setCommentBody("Which flag?", for: id)
        form = try formOf(model, snapshot)
        XCTAssertTrue(form.canRequestChanges)
        XCTAssertNil(form.requestChangesHint)

        model.removeComment(id)
        model.setNote("Split the rollout")
        XCTAssertTrue(try formOf(model, snapshot).canRequestChanges, "a note is enough")

        await model.review(.changes, ask)
        let answer = try AskAnswerParams(wireParams: try XCTUnwrap(try fixture.store.pendingActions().first).action.params).answer
        XCTAssertEqual(answer.verdict, .changes)
        XCTAssertEqual(answer.note, "Split the rollout")
        XCTAssertNil(try formOf(model, snapshot).requestChangesHint, "no hint while the answer is on its way")
    }

    func testAReviewCommentAnchorsOnTheShownTextAndApproveSends() async throws {
        let fixture = try await makeFixture()
        let ask = try makeAsk(130, Self.review)
        let snapshot = try replica([ask])
        let model = AskViewModel(askID: 130, drafts: fixture.drafts, answerer: fixture.answerer)
        let document = try XCTUnwrap(try formOf(model, snapshot).review?.document)
        XCTAssertFalse(try formOf(model, snapshot).canSend, "a review needs a verdict")
        XCTAssertTrue(try formOf(model, snapshot).canSendVerdict, "which Approve and Request changes give")

        XCTAssertNil(model.addComment(on: NSRange(location: 3, length: 0), in: document, body: "x"), "an empty selection")
        let id = try XCTUnwrap(model.addComment(on: NSRange(location: 6, length: 4), in: document, body: ""))
        model.setCommentBody("Which flag?", for: id)
        model.addComment(on: NSRange(location: 11, length: 6), in: document, body: "   ")
        XCTAssertEqual(try formOf(model, snapshot).review?.commentsLine, "Press and hold a paragraph to comment · 2 comments")

        await model.review(.approved, ask)
        let row = try XCTUnwrap(try fixture.store.pendingActions().first)
        let answer = try AskAnswerParams(wireParams: row.action.params).answer
        XCTAssertEqual(answer.verdict, .approved)
        XCTAssertEqual(answer.comments, [
            OwnerAskAnswer.Comment(quote: "Ship", prefix: "Plan\n\n", suffix: " behind a flag for acme.\n\n", heading: "Plan", body: "Which flag?")
        ], "the blank comment is dropped, the other anchored as Core anchors it")
    }

    /// Typing rebuilds the form on every keystroke: the snapshot is
    /// rendered once per ask and snapshot, not once per build.
    func testTheSnapshotRendersOncePerAskAndSnapshot() async throws {
        let fixture = try await makeFixture()
        let renders = Counter()
        let model = AskViewModel(askID: 130, drafts: fixture.drafts, answerer: fixture.answerer) { markdown in
            renders.count += 1
            return PlainTextRendering.render(markdown)
        }
        let snapshot = try replica([try makeAsk(130, Self.review)])
        for text in ["a", "ab", "abc"] {
            model.setNote(text)
            XCTAssertNotNil(try formOf(model, snapshot).review?.document)
        }
        XCTAssertEqual(renders.count, 1)

        var revised = Self.review
        revised["doc_snapshot"] = "# Plan\n\nShip it.\n"
        XCTAssertEqual(try formOf(model, try replica([try makeAsk(130, revised)])).review?.document?.text, "Plan\n\nShip it.\n\n")
        XCTAssertEqual(renders.count, 2, "a new snapshot renders again")
    }

    // MARK: - Check

    func testABrokenStepNeedsANoteAndUnmarkedStepsGoAsSkipped() async throws {
        let fixture = try await makeFixture()
        let ask = try makeAsk(140, [
            "kind": "check", "payload": ["checklist": [["id": "1", "text": "Open the menu"], ["id": "2", "text": "Archive", "hint": "Header menu"]]]
        ])
        let snapshot = try replica([ask])
        let model = AskViewModel(askID: 140, drafts: fixture.drafts, answerer: fixture.answerer)
        XCTAssertEqual(try formOf(model, snapshot).checks.map(\.text), ["Open the menu", "Archive"])
        XCTAssertFalse(try formOf(model, snapshot).canSend, "#1787: nothing marked, nothing to send")
        XCTAssertEqual(
            try formOf(model, snapshot).checkFooter,
            "Mark at least one step to send. A step you leave unmarked goes as Didn't check."
        )

        model.setCheck(.ok, for: "2")
        XCTAssertTrue(try formOf(model, snapshot).canSend, "one mark is enough; the unmarked step goes as skipped")
        XCTAssertEqual(try formOf(model, snapshot).checkFooter, "A step you leave unmarked goes as Didn't check.")
        model.setCheck(nil, for: "2")

        model.setCheck(.broken, for: "1")
        XCTAssertTrue(try XCTUnwrap(try formOf(model, snapshot).checks.first).needsNote)
        XCTAssertFalse(try formOf(model, snapshot).canSend)
        model.setCheckNote("The menu is empty", for: "1")
        model.setCheck(.ok, for: "2")
        XCTAssertTrue(try formOf(model, snapshot).canSend)

        await model.send(ask)
        let answer = try AskAnswerParams(wireParams: try XCTUnwrap(try fixture.store.pendingActions().first).action.params).answer
        XCTAssertEqual(answer.checklist, [.init(id: "1", state: .broken, note: "The menu is empty"), .init(id: "2", state: .ok)])
        XCTAssertNil(answer.verdict)
    }

    /// Design pass A5: three icon buttons, one tap marks a step, the marked
    /// state draws filled in its tone, and tapping it again clears it, as
    /// on the Mac (`OwnerAskChecklistBody.swift:44-57`).
    func testOneTapMarksAStepAndASecondTapClearsIt() async throws {
        let fixture = try await makeFixture()
        let ask = try makeAsk(140, ["kind": "check", "payload": ["checklist": [["id": "1", "text": "Open the menu"]]]])
        let snapshot = try replica([ask])
        let model = AskViewModel(askID: 140, drafts: fixture.drafts, answerer: fixture.answerer)
        func row() throws -> AskFormModel.CheckRow {
            try XCTUnwrap(try formOf(model, snapshot).checks.first)
        }

        XCTAssertEqual(try row().choices.map(\.label), ["Works", "Doesn't work", "Didn't check"], "the tower drawer's words")
        XCTAssertEqual(try row().choices.map(\.symbol), ["checkmark.circle", "xmark.circle", "minus.circle"])
        XCTAssertTrue(try row().choices.allSatisfy { $0.tone == .secondary && !$0.isSelected }, "unmarked: outlines in secondary")

        model.toggleCheck(.ok, for: "1")
        XCTAssertEqual(try row().state, .ok)
        XCTAssertEqual(try row().choices.map(\.symbol), ["checkmark.circle.fill", "xmark.circle", "minus.circle"])
        XCTAssertEqual(try row().choices.map(\.tone), [.green, .secondary, .secondary])

        model.toggleCheck(.broken, for: "1")
        XCTAssertEqual(try row().state, .broken, "another state replaces the mark")
        XCTAssertEqual(try row().choices.map(\.tone), [.secondary, .red, .secondary])
        XCTAssertTrue(try row().needsNote)

        model.toggleCheck(.broken, for: "1")
        XCTAssertNil(try row().state, "tapping the marked state again clears it")

        model.toggleCheck(.skipped, for: "1")
        XCTAssertEqual(try row().choices.map(\.isSelected), [false, false, true])
        XCTAssertEqual(try row().choices.map(\.tone), [.secondary, .secondary, .secondary], "skipped stays secondary")
    }

    /// The check states are status tones in the form's `toneUses`, so the
    /// orange sweep sees them; none is orange.
    func testTheCheckStatesAreStatusTonesAndNeverOrange() async throws {
        let fixture = try await makeFixture()
        let ask = try makeAsk(140, ["kind": "check", "payload": ["checklist": [["id": "1", "text": "Open"], ["id": "2", "text": "Archive"]]]])
        let snapshot = try replica([ask])
        let model = AskViewModel(askID: 140, drafts: fixture.drafts, answerer: fixture.answerer)
        model.toggleCheck(.ok, for: "1")
        model.toggleCheck(.broken, for: "2")
        let steps = try formOf(model, snapshot).toneUses.filter { $0.element.contains(" step ") }
        XCTAssertEqual(steps.count, 6, "three choices per step")
        XCTAssertTrue(steps.allSatisfy { $0.role == .status })
        XCTAssertEqual(Set(steps.map(\.tone)), [.green, .red, .secondary])
    }

    func testANoteOverTheBoundSaysWhySendIsOff() async throws {
        let fixture = try await makeFixture()
        let ask = try makeAsk(140, ["kind": "check", "payload": ["checklist": [["id": "1", "text": "Open"]]]])
        let model = AskViewModel(askID: 140, drafts: fixture.drafts, answerer: fixture.answerer)
        let snapshot = try replica([ask])
        model.setCheck(.ok, for: "1")
        model.setNote(String(repeating: "a", count: 4_000))
        XCTAssertNil(try formOf(model, snapshot).noteHint)
        XCTAssertTrue(try formOf(model, snapshot).canSend)

        model.setNote(String(repeating: "a", count: 4_001))
        XCTAssertEqual(try formOf(model, snapshot).noteHint, "The note is over 4000 characters — shorten it to send")
        XCTAssertFalse(try formOf(model, snapshot).canSend)
    }

    // MARK: - Payload clipped, closed asks

    func testAClippedPayloadOffersOnlyOpenOnTheMac() async throws {
        let fixture = try await makeFixture()
        let snapshot = try replica([try makeAsk(150, ["kind": "question", "payload_clipped": true])])
        let model = AskViewModel(askID: 150, drafts: fixture.drafts, answerer: fixture.answerer)
        let form = try formOf(model, snapshot)

        XCTAssertEqual(form.openOnMac, "Open the ask on the tower")
        XCTAssertNil(form.question)
        XCTAssertNil(form.review)
        XCTAssertTrue(form.checks.isEmpty)
        XCTAssertFalse(form.isEditable)
        XCTAssertFalse(form.canSend)
    }

    func testAClosedAskShowsItsStoredAnswerReadOnly() async throws {
        let fixture = try await makeFixture()
        let snapshot = try replica([try makeAsk(160, [
            "kind": "question", "status": "delivered",
            "payload": ["questions": [["id": "q", "question": "Keep the counter?", "options": [["label": "Yes"], ["label": "No"]]]]],
            "answer": ["verdict": "", "answers": [["id": "q", "labels": ["No"], "other": ""]], "checklist": [], "comments": [], "note": "Not needed"]
        ])])
        let model = AskViewModel(askID: 160, drafts: fixture.drafts, answerer: fixture.answerer)
        let form = try formOf(model, snapshot)

        XCTAssertEqual(form.closedStatus, "Answered and delivered")
        XCTAssertEqual(form.closedLines, [
            AskFormModel.ClosedLine(label: "Keep the counter?", value: "No"),
            AskFormModel.ClosedLine(label: "Note", value: "Not needed")
        ], "the question over its answer: no \"?:\" (design pass A6)")
        XCTAssertNil(form.question)
        XCTAssertFalse(form.isEditable)
        XCTAssertNil(form.openOnMac, "a closed ask is shown, not sent to the tower")
    }

    /// Board #223: an ask the owner dismissed on the Mac says so, never an
    /// empty "Answered".
    func testADismissedAskSaysDismissed() async throws {
        let fixture = try await makeFixture()
        let snapshot = try replica([try makeAsk(162, [
            "kind": "check", "status": "answered",
            "payload": ["checklist": [["id": "1", "text": "Open the menu"]]],
            "answer": ["verdict": "", "answers": [[String: Any]](), "checklist": [[String: Any]](), "comments": [[String: Any]](),
                       "dismissed": true, "note": "Not now"]
        ])])
        let form = try formOf(AskViewModel(askID: 162, drafts: fixture.drafts, answerer: fixture.answerer), snapshot)
        XCTAssertEqual(form.closedStatus, "Dismissed")
        XCTAssertEqual(form.closedLines, [
            AskFormModel.ClosedLine(label: "Dismissed", value: "Closed without answering"),
            AskFormModel.ClosedLine(label: "Note", value: "Not now")
        ])
    }

    /// Design pass A6 and review focus 1: each stored part is a label over a
    /// value; a question answered with nothing reads "No answer", never an
    /// empty line.
    func testAClosedAnswerIsLabelAndValuePairs() async throws {
        let fixture = try await makeFixture()
        let snapshot = try replica([try makeAsk(161, [
            "kind": "check", "status": "answered",
            "payload": [
                "questions": [["id": "q", "question": "Keep it?", "options": [["label": "Yes"], ["label": "No"]]]],
                "checklist": [["id": "1", "text": "Open the menu"]]
            ],
            "answer": [
                "verdict": "approved", "answers": [["id": "q", "labels": [String](), "other": ""]],
                "checklist": [["id": "1", "state": "broken", "note": "The menu is empty"]], "comments": [[String: Any]](), "note": ""
            ]
        ])])
        let form = try formOf(AskViewModel(askID: 161, drafts: fixture.drafts, answerer: fixture.answerer), snapshot)
        XCTAssertEqual(form.closedLines, [
            AskFormModel.ClosedLine(label: "Verdict", value: "Approved"),
            AskFormModel.ClosedLine(label: "Keep it?", value: "No answer"),
            AskFormModel.ClosedLine(label: "Open the menu", value: "Doesn't work — The menu is empty")
        ])
    }

    // MARK: - On its way and back

    func testAPendingAnswerSaysWaitingForYourMacWhileTheHeartbeatIsStale() async throws {
        let fixture = try await makeFixture()
        let ask = try makeAsk(140, ["kind": "check", "payload": ["checklist": [["id": "1", "text": "Open"]]]])
        let model = AskViewModel(askID: 140, drafts: fixture.drafts, answerer: fixture.answerer)
        await model.send(ask)

        let online = try formOf(model, try replica([ask], store: fixture.store))
        XCTAssertEqual(online.status, .sending("Sending…"))
        XCTAssertFalse(online.isEditable)
        XCTAssertFalse(online.canSend)
        let stale = try formOf(model, try replica([ask], store: fixture.store, heartbeatAge: 3_600))
        XCTAssertEqual(stale.status, .sending("Waiting for your tower"))
    }

    func testAnAppliedEchoShowsTheDeliveryAndClearsTheDraft() async throws {
        let fixture = try await makeFixture()
        let ask = try makeAsk(140, ["kind": "check", "payload": ["checklist": [["id": "1", "text": "Open"]]]])
        let model = AskViewModel(askID: 140, drafts: fixture.drafts, answerer: fixture.answerer)
        model.setNote("All good")
        await model.send(ask)

        try await echo(fixture, .applied, result: ["delivery": .string("held")])
        try await poll { fixture.answerer.applied[140] != nil }

        let form = try formOf(model, try replica([ask], store: fixture.store))
        XCTAssertEqual(form.status, .applied("Held until the session is free"))
        XCTAssertFalse(form.isEditable, "an applied answer is not sent again")
        XCTAssertNil(fixture.drafts.byAsk[140], "a successful answer clears the draft")
        XCTAssertEqual(AskDelivery.noSession.text, "No session is running — the answer is saved on the tower")
        XCTAssertEqual(AppliedAnswer(delivery: nil).text, "Answer saved on the tower")
    }

    /// Live link R5: an answer adds an `ask_answer` overlay. Between the applied echo (which removes the row) and
    /// the asks slice, Now keeps "Sending answer…" instead of offering the ask again, and the form shows the
    /// delivery; the slice that closes the ask drops the overlay.
    func testAnAnsweredAskStaysSendingUntilItsSliceArrives() async throws {
        let store = try TestPhone.replica()
        let outbox = ActionOutbox(transport: try TestPhone.transport(), store: store, deviceID: DemoSeed.device.deviceID)
        let book = OverlayBook(hubID: "hub")
        let drafts = AskDraftStore()
        let answerer = AskAnswerer.sending(through: outbox, store: store, drafts: drafts, overlays: book)
        await outbox.setAppliedObserver(HubSession.appliedObserver(
            askAnswerer: answerer, sessionStarts: SessionStarter.sending(through: outbox, store: store), overlays: book))
        let ask = try makeAsk(140, ["kind": "check", "payload": ["checklist": [["id": "1", "text": "Open"]]]])
        let model = AskViewModel(askID: 140, drafts: drafts, answerer: answerer)
        model.setNote("All good")
        await model.send(ask)
        XCTAssertEqual(book.overlays.map(\.kind), [.askAnswer])
        XCTAssertEqual(book.overlays.first?.entityID, 140)
        XCTAssertEqual(book.overlays.first?.expected, .askAnswer(label: nil), "a check has no option to name")

        var echo = try XCTUnwrap(store.pendingActions().first).action
        echo.status = .applied
        echo.result = ["delivery": .string("held")]
        try await outbox.applyEcho(echo)
        try await poll { answerer.applied[140] != nil && book.overlays.first?.echo != nil }

        let open = try replica([ask], store: store)
        XCTAssertTrue(open.pending.isEmpty, "applied removed the row")
        let shown = open.applying(book.reconcile(with: open, now: now))
        XCTAssertEqual(NowModel(snapshot: shown, linked: true, now: now).waitingForYou.first { $0.id == .ask(140) }?.answer,
                       .sending(NowAnswer.sendingText))
        XCTAssertEqual(NowModel(snapshot: open, linked: true, now: now).waitingForYou.first { $0.id == .ask(140) }?.answer,
                       NowAnswer.none, "without the overlay the ask would ask again")
        XCTAssertEqual(try formOf(model, shown).status, .applied("Held until the session is free"))

        let closed = try replica([try makeAsk(140, ["kind": "check", "status": "answered"])], store: store)
        XCTAssertTrue(book.reconcile(with: closed, now: now).isEmpty)
        XCTAssertTrue(book.overlays.isEmpty)
    }

    /// An automation's ask (the Mac's `automationAnswerNote`); a delivery
    /// this build does not know shows the plain saved line.
    func testAnAutomationEchoSaysTheAutomationGoesOn() async throws {
        let fixture = try await makeFixture()
        let ask = try makeAsk(140, ["kind": "check", "payload": ["checklist": [["id": "1", "text": "Open"]]]])
        let model = AskViewModel(askID: 140, drafts: fixture.drafts, answerer: fixture.answerer)
        model.setNote("All good")
        await model.send(ask)

        try await echo(fixture, .applied, result: ["delivery": .string("automation")])
        try await poll { fixture.answerer.applied[140] != nil }

        let form = try formOf(model, try replica([ask], store: fixture.store))
        XCTAssertEqual(form.status, .applied("Answer saved — the automation goes on with it"))
        XCTAssertNil(AskDelivery(rawValue: "from_a_newer_mac"))
    }

    func testAnInvalidAnswerEchoShowsTheMacsMessageAndKeepsTheDraft() async throws {
        let fixture = try await makeFixture()
        let ask = try makeAsk(140, ["kind": "check", "payload": ["checklist": [["id": "1", "text": "Open"]]]])
        let model = AskViewModel(askID: 140, drafts: fixture.drafts, answerer: fixture.answerer)
        model.setNote("All good")
        await model.send(ask)
        try await echo(fixture, .failed, reason: .invalidAnswer, message: "checklist: item \"1\" has no state")

        let rowID = try XCTUnwrap(try fixture.store.pendingActions().first).id
        let form = try formOf(model, try replica([ask], store: fixture.store))
        XCTAssertEqual(form.status, .failed("checklist: item \"1\" has no state", rowID: rowID))
        XCTAssertTrue(form.isEditable)
        XCTAssertEqual(model.draft.note, "All good")

        model.dismiss(rowID: rowID, snapshot: try replica([ask], store: fixture.store))
        XCTAssertTrue(try fixture.store.pendingActions().isEmpty)
    }

    /// A resend after a refusal: once it is queued the refused row goes, so
    /// the later `applied` shows its delivery, never the old refusal.
    func testAResendAfterARefusalShowsTheAppliedDeliveryAndNoStaleRow() async throws {
        let fixture = try await makeFixture()
        let ask = try makeAsk(140, ["kind": "check", "payload": ["checklist": [["id": "1", "text": "Open"]]]])
        let model = AskViewModel(askID: 140, drafts: fixture.drafts, answerer: fixture.answerer)
        model.setNote("All good")
        await model.send(ask)
        try await echo(fixture, .failed, reason: .invalidAnswer, message: "note: at most 4000 characters")

        await model.send(ask)
        let rows = try fixture.store.pendingActions()
        XCTAssertEqual(rows.map(\.state), [.pending], "the refused row went once the resend was queued")
        try await echo(fixture, .applied, result: ["delivery": .string("submitted")])
        try await poll { fixture.answerer.applied[140] != nil }

        XCTAssertTrue(try fixture.store.pendingActions().isEmpty, "no red row is left")
        XCTAssertEqual(try formOf(model, try replica([ask], store: fixture.store)).status, .applied("Sent to the session"))
    }

    /// Review Focus 3: the owner drafts on a review the agent replaced with
    /// a newer round meanwhile. The answer fails `ask_not_open`; the phone
    /// opens the newer round (`previous_ask_id` chain, followed to its open
    /// end) and keeps the old draft's text.
    func testASupersededAskFailsAskNotOpenAndMovesToTheNewRoundWithTheDraftText() async throws {
        let fixture = try await makeFixture()
        let old = try makeAsk(170, Self.review)
        let model = AskViewModel(askID: 170, drafts: fixture.drafts, answerer: fixture.answerer)
        let document = try XCTUnwrap(try formOf(model, try replica([old])).review?.document)
        model.addComment(on: NSRange(location: 6, length: 4), in: document, body: "Which flag?")
        model.setNote("Looks fine otherwise")
        await model.review(.changes, old)
        try await echo(fixture, .failed, reason: .askNotOpen, message: "The ask is no longer open")

        // The replica caught up: the old round withdrawn, a middle round
        // withdrawn too, the newest one open.
        let withdrawn = try makeAsk(170, Self.review.merging(["status": "withdrawn", "withdrawn_reason": "superseded"]) { _, new in new })
        let middle = try makeAsk(171, Self.review.merging([
            "status": "withdrawn", "withdrawn_reason": "superseded", "previous_ask_id": 170
        ]) { _, new in new })
        let newest = try makeAsk(172, Self.review.merging(["previous_ask_id": 171, "title": "Review the plan, round 3"]) { _, new in new })
        let caughtUp = try replica([withdrawn, middle, newest], store: fixture.store)

        let rowID = try XCTUnwrap(try fixture.store.pendingActions().first).id
        XCTAssertEqual(
            try formOf(model, caughtUp).status,
            .notOpen("This ask is no longer open: Replaced by a newer round", rowID: rowID, successor: 172)
        )

        XCTAssertTrue(model.followSuccessor(snapshot: caughtUp, now: now))
        XCTAssertEqual(model.askID, 172)
        XCTAssertEqual(model.carriedNotice, "This ask was replaced by a newer round. Your earlier draft is in the note.")
        XCTAssertEqual(model.draft.note, "“Ship” — Which flag?\n\nLooks fine otherwise")
        XCTAssertNil(model.draft.verdict, "the verdict is not carried over")
        XCTAssertTrue(model.draft.comments.isEmpty, "anchors do not carry over to another snapshot")
        let carriedReview = try XCTUnwrap(try formOf(model, caughtUp).review)
        XCTAssertTrue(carriedReview.commentsByParagraph.isEmpty && carriedReview.unplacedComments.isEmpty,
                      "#1787: no old location is placed on the new round's text; the comment lives in the note")
        XCTAssertNil(fixture.drafts.byAsk[170], "the old draft went")
        XCTAssertTrue(try fixture.store.pendingActions().isEmpty, "the failed answer row went")

        let moved = try formOf(model, try replica([withdrawn, middle, newest], store: fixture.store))
        XCTAssertEqual(moved.title, "Review the plan, round 3")
        XCTAssertTrue(moved.isEditable)
        XCTAssertEqual(moved.status, AskFormModel.Status.none)
    }

    func testAskNotOpenWithoutANewerRoundStaysAndShowsTheStatus() async throws {
        let fixture = try await makeFixture()
        let open = try makeAsk(180, ["kind": "check", "payload": ["checklist": [["id": "1", "text": "Open"]]]])
        let model = AskViewModel(askID: 180, drafts: fixture.drafts, answerer: fixture.answerer)
        await model.send(open)
        try await echo(fixture, .failed, reason: .askNotOpen)
        let answered = try makeAsk(180, ["kind": "check", "status": "answered", "payload": ["checklist": [["id": "1", "text": "Open"]]]])
        let caughtUp = try replica([answered], store: fixture.store)

        let rowID = try XCTUnwrap(try fixture.store.pendingActions().first).id
        XCTAssertEqual(try formOf(model, caughtUp).status, .notOpen("This ask is no longer open: Answered", rowID: rowID, successor: nil))
        XCTAssertFalse(model.followSuccessor(snapshot: caughtUp, now: now))
        XCTAssertEqual(model.askID, 180)
    }

    // MARK: - The demo

    func testTheDemoReachesOneAskOfEachKind() async throws {
        let fixture = try await makeFixture()
        let demo = try demoSnapshot(now: now)
        func form(_ id: Int64) throws -> AskFormModel {
            try XCTUnwrap(AskViewModel(askID: id, drafts: fixture.drafts, answerer: fixture.answerer).form(snapshot: demo, now: now))
        }
        XCTAssertEqual(try form(109).question?.options.map(\.label), ["Archive Closed Targets Now", "Archive Now"])
        let review = try XCTUnwrap(try form(110).review)
        XCTAssertNotNil(review.document)
        XCTAssertNotNil(review.clippedNotice)
        XCTAssertNil(AskFormModel.successor(of: 110, in: demo), "110 is the open round of the superseded #107")
        XCTAssertEqual(AskFormModel.successor(of: 107, in: demo)?.id, 110)
        XCTAssertEqual(try form(111).checks.count, 2)
        XCTAssertEqual(try form(105).closedLines, [
            AskFormModel.ClosedLine(label: "Keep the archived counter?", value: "Drop it"),
            AskFormModel.ClosedLine(label: "Note", value: "Not needed on the board.")
        ])
    }

    // MARK: - One answer per ask in flight

    /// A second Send while the first is still being saved sends nothing.
    /// Bounded: the second call runs in its own Task and must finish within
    /// seconds; a missing guard fails here, it never hangs.
    func testASecondSendWhileTheFirstIsSavingSendsNothing() async throws {
        let gate = Gate()
        let drafts = AskDraftStore()
        let sent = Counter()
        let answerer = AskAnswerer(
            drafts: drafts,
            enqueue: { _, _, _ in
                sent.count += 1
                await gate.wait()
                return "action"
            },
            remove: { _ in }
        )
        let ask = try makeAsk(140, ["kind": "check", "payload": ["checklist": [["id": "1", "text": "Open"]]]])

        let first = Task { try await answerer.send(ask) }
        // Released on every path, so a failing assertion leaks no waiter.
        defer { Task { await gate.release() } }
        try await poll { sent.count == 1 }
        XCTAssertTrue(answerer.isSending(140))

        let secondDone = expectation(description: "the second send returns")
        let secondSent = Counter(-1)
        Task {
            secondSent.count = try await answerer.send(ask) ? 1 : 0
            secondDone.fulfill()
        }
        await fulfillment(of: [secondDone])
        XCTAssertEqual(secondSent.count, 0, "the second send sent nothing")
        XCTAssertEqual(sent.count, 1)

        await gate.release()
        let firstSent = try await first.value
        XCTAssertTrue(firstSent)
        XCTAssertFalse(answerer.isSending(140))
    }
}

/// A gate the first enqueue waits on; releasing is sticky, so any later
/// waiter passes at once.
private actor Gate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

@MainActor
private final class Counter {
    var count: Int

    init(_ count: Int = 0) {
        self.count = count
    }
}

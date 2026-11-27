import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// "Not clear?" on each item of an ask (#2412) as built: the real
/// `OwnerAskDrawer`, its per-question and per-step entries and
/// `AskExplainPane`, over a test workbench, the app's embedded chat center and
/// a scripted AI service, in every state of the 2026-11-27 spec's States
/// table. Compared with the approved mockups in
/// `docs/design/mockups/ask-explain-per-item/` (`AskExplainItemsMockShotFixtures`),
/// whose sample asks it files. Sample data only.
@MainActor
enum AskExplainBuiltShotFixtures {
    enum State: String, CaseIterable {
        case itemsEntry = "items-entry"
        case checkEntry = "check-entry"
        case finding, queued, loading
        /// Question 2's chat, explained.
        case explained
        /// Step 2's chat, explained.
        case step
        /// The long question's chat: its card clamped with Show more.
        case long
        /// The same card after Show more.
        case expanded
        case busy, error, narrow
        /// A hidden first turn that failed before it started.
        case errorStart = "error-start"
        /// The open itself failed: the workbench is gone.
        case errorOpen = "error-open"

        var width: CGFloat { self == .narrow ? 320 : 440 }

        /// The mockups' entry shot of three questions is taller than the drawer.
        var height: CGFloat { self == .itemsEntry ? 760 : AskExplainBuiltShotFixtures.height }

        var ask: Sample.Ask {
            switch self {
            case .checkEntry, .step: .check
            case .long, .expanded: .long
            default: .questions
            }
        }

        /// The item whose chat the shot opens.
        var item: AskExplainItem { ask == .check ? .step(2) : .question(2) }
    }

    static let height: CGFloat = 620

    /// Each shot's scene, kept alive until `cleanUp`.
    private static var scenes: [Scene] = []

    static var shots: [DesignShot] {
        State.allCases.map { state in
            DesignShot(name: "ask-explain-built-\(state.rawValue)", prepare: { try await view(state) },
                       size: NSSize(width: state.width, height: state.height))
        }
    }

    static func cleanUp() {
        scenes.forEach { $0.cleanUp() }
        scenes = []
    }

    // MARK: - Scenes

    private static func view(_ state: State) async throws -> AnyView {
        let scene = try Scene(state.ask, gateLimit: state == .queued ? 1 : 3, holdChatNew: state == .finding)
        scenes.append(scene)
        let ask = try await scene.open()
        let asks = scene.vm.asks
        let item = state.item
        switch state {
        case .itemsEntry, .checkEntry:
            break
        case .finding:
            scene.openTask = Task { await asks.openExplain(ask, item: item) }
            await waitForCondition { asks.isExplaining(ask.id) }
        case .queued:
            // The gate's only place is taken by another chat's turn.
            _ = scene.gate.tryAcquire(UUID())
            await asks.openExplain(ask, item: item)
        case .loading:
            await asks.openExplain(ask, item: item)
            try await XCTUnwrap(asks.explainEngine(for: ask, item: item)).started()
        case .explained, .narrow, .step, .long, .expanded:
            try await scene.store(ask, item: item)
            await asks.openExplain(ask, item: item)
        case .busy:
            try await scene.store(ask, item: item)
            await asks.openExplain(ask, item: item)
            let engine = try XCTUnwrap(asks.explainEngine(for: ask, item: item))
            guard engine.send(Sample.busyQuestion) else { throw NoTurn(what: "the follow-up was refused") }
            await engine.started()
            try scene.requireCall(1)
            scene.ai.emit(.text(Sample.streamingReply))
            await waitForCondition { engine.liveTurn?.text.isEmpty == false }
        case .error:
            await asks.openExplain(ask, item: item)
            let engine = try XCTUnwrap(asks.explainEngine(for: ask, item: item))
            await engine.started()
            try scene.requireCall(1)
            scene.ai.emit(.error(Sample.turnError), .done)
            scene.ai.finish()
            await waitForCondition { !engine.isBusy }
            await engine.finished()
        case .errorStart:
            scene.ai.persistStartError = EarlyExit()
            await asks.openExplain(ask, item: item)
            await asks.explainEngine(for: ask, item: item)?.finished()
        case .errorOpen:
            try await scene.dropWorkbench()
            await asks.openExplain(ask, item: item)
        }
        let drawer = scene.drawer(ask)
        // Show more pressed, through the card's own state.
        return state == .expanded ? AnyView(drawer.environment(\.askExplainCardStartsExpanded, true)) : drawer
    }

    /// The question view of the three-question ask scrolled to its bottom
    /// (question 3), question 3's chat opened and closed again through the
    /// view model, drawn after the close in the same window: question 3 must
    /// still be where it was. Returns the PNG and the scroll offset (bottom
    /// expected) after the close.
    static func backScrolled(_ appearance: NSAppearance) throws -> (png: Data, offset: CGFloat, bottom: CGFloat) {
        let scene = try Scene(.questions, gateLimit: 3, holdChatNew: false)
        scenes.append(scene)
        var opened: OwnerAsk?
        run("the asks did not load") { opened = try? await scene.open() }
        let ask = try XCTUnwrap(opened)
        let size = NSSize(width: 440, height: height)
        let root = scene.drawer(ask)
            .frame(width: size.width, height: size.height)
            .environment(\.controlActiveState, .key)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = host
        defer { window.close() }
        settle(host)

        let scroll = try XCTUnwrap(questionScroll(in: host), "the question view has no scroll view to scroll")
        let bottom = scrollToBottom(scroll)
        XCTAssertGreaterThan(bottom, 0, "the three questions must overflow the drawer")
        settle(host)

        run("the open did not finish") { await scene.vm.asks.openExplain(ask, item: .question(3)) }
        settle(host)
        XCTAssertEqual(scene.vm.asks.explainItem(ask.id), .question(3))
        scene.vm.asks.closeExplain(ask.id)
        settle(host)
        XCTAssertFalse(scene.vm.asks.isExplaining(ask.id))

        let after = try XCTUnwrap(questionScroll(in: host), "the question view is gone after the chat closed")
        let offset = offset(after)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        context.cgContext.translateBy(x: 0, y: size.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        try XCTUnwrap(host.layer).render(in: context.cgContext)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        return (png, offset, bottom)
    }

    private static func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
    }

    /// Runs `work` to its end on the main run loop (a test method is not on
    /// the main actor's executor), as `DesignShotsTests.prepared` does.
    fileprivate static func run(_ failure: String, _ work: @escaping @MainActor () async -> Void) {
        final class Box { var done = false }
        let box = Box()
        Task { @MainActor in
            await work()
            box.done = true
        }
        var left = DesignShotsTests.preparationTurns
        while !box.done, left > 0 {
            RunLoop.main.run(mode: .default, before: .distantPast)
            left -= 1
        }
        XCTAssertTrue(box.done, failure)
    }

    /// The tallest scrolling view in the drawer: the question view's.
    private static func questionScroll(in view: NSView) -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, !scroll.isHiddenOrHasHiddenAncestor { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found.max { overflow($0) < overflow($1) }
    }

    private static func overflow(_ scroll: NSScrollView) -> CGFloat {
        (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height
    }

    private static func scrollToBottom(_ scroll: NSScrollView) -> CGFloat {
        let bottom = overflow(scroll)
        guard bottom > 0, let document = scroll.documentView else { return bottom }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? bottom : 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        return bottom
    }

    /// How far from the top the view is scrolled.
    private static func offset(_ scroll: NSScrollView) -> CGFloat {
        let y = scroll.contentView.bounds.origin.y
        return scroll.documentView?.isFlipped == false ? overflow(scroll) - y : y
    }

    struct NoTurn: LocalizedError {
        let what: String
        var errorDescription: String? { what }
    }

    private struct EarlyExit: LocalizedError {
        var errorDescription: String? { "the CLI exited before it answered." }
    }

    // MARK: - Sample

    /// The mockups' sample asks (`AskExplainItemsMock`), filed as Go files them.
    enum Sample {
        typealias Mock = AskExplainItemsMock

        enum Ask {
            /// Three questions.
            case questions
            /// Four steps.
            case check
            /// The mockups' first question, then their long question.
            case long

            var kind: String { self == .check ? "check" : "question" }
            var title: String { self == .check ? Mock.checkTitle : Mock.questionTitle }

            var payload: String {
                switch self {
                case .questions: Sample.questionsPayload(Mock.questions)
                case .long: Sample.questionsPayload([Mock.questions[0], Mock.longQuestion])
                case .check: Sample.json(["checklist": Mock.steps.map { ["text": $0.text, "hint": $0.hint] }])
                }
            }

            /// The stored explanation of the item the shot opens.
            var explanation: String {
                let paragraphs = switch self {
                case .questions: Mock.questionExplanation
                case .check: Mock.stepExplanation
                case .long: Mock.longExplanation
                }
                return paragraphs.joined(separator: "\n\n")
            }
        }

        fileprivate static func questionsPayload(_ questions: [Mock.Question]) -> String {
            json(["questions": questions.enumerated().map { index, question -> [String: Any] in
                let options = question.options.map { option -> [String: Any] in
                    var row: [String: Any] = ["label": option.label]
                    if !option.detail.isEmpty { row["description"] = option.detail }
                    if option.recommended { row["recommended"] = true }
                    return row
                }
                return ["id": "q\(index + 1)", "question": question.text, "options": options]
            }])
        }

        fileprivate static func json(_ object: Any) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return String(bytes: data, encoding: .utf8) ?? ""
        }

        /// The workbench's two other open asks ("1 of 3").
        static let otherTitles = ["Rename the acme_auth package now or after the release?",
                                  "Run the migration on the shared database now?"]
        static let otherPayload = #"{"questions":[{"id":"a","question":"Now?","options":[{"label":"Yes"},{"label":"No"}]}]}"#
        static let busyQuestion = Mock.followUp
        static let streamingReply = Mock.followUpReply
        static let turnError = "the provider did not answer in time."
    }
}

/// One shot's world: a workbench with three open asks (the shot's sample
/// first), its view model wired to an embedded chat center over a scripted
/// AI service and a fake tower.
@MainActor
private final class Scene {
    let pool: DatabasePool
    let path: String
    let ai = ScriptedAIService()
    let tower: FakeChatTower
    let writes: ChatWrites
    let gate: EmbeddedStreamGate
    let center: EmbeddedChatCenter
    let vm: WorkbenchesViewModel
    let projectID: Int64
    private let askID: Int64
    private let subject: AskExplainBuiltShotFixtures.Sample.Ask
    private let release: AsyncStream<Void>.Continuation
    /// The finding shot's open, held at `chat.new` until `cleanUp`.
    var openTask: Task<Void, Never>?

    init(_ subject: AskExplainBuiltShotFixtures.Sample.Ask, gateLimit: Int, holdChatNew: Bool) throws {
        (pool, path) = try TestDatabase.createPool()
        (writes, tower) = FakeChatTower.writes(pool)
        let (stream, release) = AsyncStream<Void>.makeStream()
        self.release = release
        self.subject = subject
        if holdChatNew {
            // The conversation is never found: the pane stays on its spinner.
            tower.beforeApply = { command in
                guard command == .chatNew else { return }
                for await _ in stream {}
            }
        }
        let sample = AskExplainBuiltShotFixtures.Sample.self
        let (project, session, ask) = try pool.write { db -> (Int64, TerminalSession, Int64) in
            let id = try TestDatabase.insertWorkbench(db, name: "acme", folder: "/tmp/acme")
            let session = try TerminalSessionQueries.create(
                db, .init(projectID: id, kind: .shell, title: "Guard agent settings writes", folderPath: "/tmp/acme"))
            let ask = try TestDatabase.insertOwnerAsk(db, projectID: id, sessionID: session.id, kind: subject.kind,
                                                      title: subject.title, payload: subject.payload)
            for title in sample.otherTitles {
                _ = try TestDatabase.insertOwnerAsk(db, projectID: id, sessionID: session.id, title: title,
                                                    payload: sample.otherPayload)
            }
            return (id, session, ask)
        }
        projectID = project
        askID = ask
        let gate = EmbeddedStreamGate(limit: gateLimit)
        self.gate = gate
        let (pool, writes, ai) = (pool, writes, ai)
        center = EmbeddedChatCenter(gate: gate) { spec, gate in
            EmbeddedChatEngine(spec: spec,
                               store: DatabaseEmbeddedChatStore(dbPool: pool, writes: writes,
                                                                conversationID: spec.key.conversationID ?? 0),
                               aiService: ai, gate: gate)
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: DesignShotFixtures.defaultsSuite))
        vm = WorkbenchesViewModel(dbPool: pool, cli: nil, defaults: defaults)
        vm.selectedWorkbenchID = project
        vm.terminalSessions[project] = [session]
        vm.asks.chats = center
        vm.asks.chatWrites = writes
        vm.asks.explainCatalog = AIModelCatalog(providers: ProviderCatalogFixture.providers())
        vm.asks.explainConfigProvider = { "claude" }
    }

    /// Lists the workbench's open asks ("1 of 3") and opens the first one's drawer.
    func open() async throws -> OwnerAsk {
        await vm.asks.load(projectID: projectID)
        let ask = try ask
        vm.asks.openDrawer(ask)
        return ask
    }

    var ask: OwnerAsk {
        get throws {
            let (askID, projectID) = (askID, projectID)
            return try XCTUnwrap(try pool.read { try OwnerAskQueries.ask($0, id: askID, projectID: projectID) })
        }
    }

    func drawer(_ ask: OwnerAsk) -> AnyView {
        AnyView(OwnerAskDrawer(vm: vm, ask: ask).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
    }

    /// The item's explanation as a stored reply: opening its chat starts nothing.
    func store(_ ask: OwnerAsk, item: AskExplainItem) async throws {
        let conversationID = try await AskExplainSurface.conversationID(ask: ask, item: item, dbPool: pool, writes: writes)
        let text = subject.explanation
        try await pool.write { db in
            _ = try TestDatabase.insertChatMessage(db, conversationID: conversationID, role: "assistant", text: text,
                                                   createdAt: Date().timeIntervalSince1970 - 600)
        }
    }

    /// Deletes the workbench row only (the asks the view model holds stay on
    /// screen), as when it is deleted while its drawer is open.
    func dropWorkbench() async throws {
        let projectID = projectID
        try await pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [projectID])
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
    }

    /// Throws unless the AI was asked for at least `count` turns, so an emit
    /// never reaches a turn that was refused.
    func requireCall(_ count: Int) throws {
        guard ai.calls.count >= count else {
            throw AskExplainBuiltShotFixtures.NoTurn(what: "no AI turn started (\(ai.calls.count) of \(count))")
        }
    }

    /// Lets the held open finish (Back was pressed, so it starts no turn),
    /// ends every turn as at quit and waits for its writes, then removes the
    /// database: nothing outlives the file.
    func cleanUp() {
        vm.asks.closeExplain(askID)
        release.finish()
        let (openTask, center) = (openTask, center)
        AskExplainBuiltShotFixtures.run("the scene's open and turns did not end") {
            await openTask?.value
            await center.finishAllAsPartialForQuit()
        }
        TestDatabase.cleanup(path: path)
    }
}

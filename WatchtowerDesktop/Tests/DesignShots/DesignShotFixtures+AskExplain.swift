import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// "Not clear?" on an ask (#2355) as built: the real `OwnerAskDrawer`, its
/// entry and `AskExplainPane`, over a test workbench, the app's embedded chat
/// center and a scripted AI service, in every state of the spec's States
/// table. Compared with the approved mockups in
/// `docs/design/mockups/ask-explain-chat/` (`AskExplainMockShotFixtures`).
/// Sample data only.
@MainActor
enum AskExplainBuiltShotFixtures {
    enum State: String, CaseIterable {
        case entry, finding, queued, loading, explained, long, busy, error, narrow
        /// A hidden first turn that failed before it started.
        case errorStart = "error-start"
        /// The open itself failed: the workbench is gone.
        case errorOpen = "error-open"

        var width: CGFloat { self == .narrow ? 320 : 440 }
    }

    static let height: CGFloat = 620

    /// Each shot's scene, kept alive until `cleanUp`.
    private static var scenes: [Scene] = []

    static var shots: [DesignShot] {
        State.allCases.map { state in
            DesignShot(name: "ask-explain-built-\(state.rawValue)", prepare: { try await view(state) },
                       size: NSSize(width: state.width, height: height))
        }
    }

    static func cleanUp() {
        scenes.forEach { $0.cleanUp() }
        scenes = []
    }

    // MARK: - Scenes

    private static func view(_ state: State) async throws -> AnyView {
        let scene = try Scene(gateLimit: state == .queued ? 1 : 3, holdChatNew: state == .finding)
        scenes.append(scene)
        let ask = try await scene.open()
        let asks = scene.vm.asks
        switch state {
        case .entry:
            break
        case .finding:
            scene.openTask = Task { await asks.openExplain(ask, item: .question(1)) }
            await waitForCondition { asks.isExplaining(ask.id) }
        case .queued:
            // The gate's only place is taken by another chat's turn.
            _ = scene.gate.tryAcquire(UUID())
            await asks.openExplain(ask, item: .question(1))
        case .loading:
            await asks.openExplain(ask, item: .question(1))
            try await XCTUnwrap(asks.explainEngine(for: ask, item: .question(1))).started()
        case .explained, .narrow:
            try await scene.store(ask, turns: 0)
            await asks.openExplain(ask, item: .question(1))
        case .long:
            try await scene.store(ask, turns: Sample.followUps.count)
            await asks.openExplain(ask, item: .question(1))
        case .busy:
            try await scene.store(ask, turns: Sample.followUps.count)
            await asks.openExplain(ask, item: .question(1))
            let engine = try XCTUnwrap(asks.explainEngine(for: ask, item: .question(1)))
            guard engine.send(Sample.busyQuestion) else { throw NoTurn(what: "the follow-up was refused") }
            await engine.started()
            try scene.requireCall(1)
            scene.ai.emit(.text(Sample.streamingReply))
            await waitForCondition { engine.liveTurn?.text.isEmpty == false }
        case .error:
            await asks.openExplain(ask, item: .question(1))
            let engine = try XCTUnwrap(asks.explainEngine(for: ask, item: .question(1)))
            await engine.started()
            try scene.requireCall(1)
            scene.ai.emit(.error(Sample.turnError), .done)
            scene.ai.finish()
            await waitForCondition { !engine.isBusy }
            await engine.finished()
        case .errorStart:
            scene.ai.persistStartError = EarlyExit()
            await asks.openExplain(ask, item: .question(1))
            await asks.explainEngine(for: ask, item: .question(1))?.finished()
        case .errorOpen:
            try await scene.dropWorkbench()
            await asks.openExplain(ask, item: .question(1))
        }
        return scene.drawer(ask)
    }

    /// The question view of a long ask scrolled to its bottom, the chat
    /// opened and closed again through the view model, drawn after the
    /// close in the same window: the question must still be at its bottom.
    /// Returns the PNG and the scroll offset (bottom expected) after the close.
    static func backScrolled(_ appearance: NSAppearance) throws -> (png: Data, offset: CGFloat, bottom: CGFloat) {
        let scene = try Scene(gateLimit: 3, holdChatNew: false, long: true)
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
        XCTAssertGreaterThan(bottom, 0, "the long question must overflow the drawer")
        settle(host)

        run("the open did not finish") { await scene.vm.asks.openExplain(ask, item: .question(1)) }
        settle(host)
        XCTAssertTrue(scene.vm.asks.isExplaining(ask.id))
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

    enum Sample {
        static let title = "Queue agent writes to its own settings (.mcp.json, hooks) for your approval?"
        static let payload = #"{"questions":[{"id":"a","question":"Queue the agent's writes to its own settings?","#
            + #""options":[{"label":"Yes, queue them","description":"The agent cannot lift its own guard from a shell; "#
            + #"normal work is not affected","recommended":true},"#
            + #"{"label":"No, keep as is","description":"Log it as an accepted risk"}]}]}"#
        static let explanation = """
            Right now an agent in the terminal can rewrite its own settings (.mcp.json, the hooks file) and so switch off the guard put on it.

            Queue means such a write is not applied at once: you get it as a separate ask with the diff and decide.

            Yes costs a rare extra ask; the agent can no longer disable its guard. \
            No keeps today's behaviour, and the risk is written to the audit log.
            """
        static let followUps: [(question: String, answer: String)] = [
            ("Will my own scripts that write .mcp.json be queued too?",
             "No. Only writes from agent sessions are queued. What you run yourself writes as before."),
            ("How often will these asks come?",
             "Rarely: an agent touches these files when it sets up a new MCP server or hook.")
        ]
        static let busyQuestion = "Which servers count as settings?"
        static let streamingReply = "Only when the agent adds or changes a server; reading them"
        static let turnError = "the provider did not answer in time."

        /// A question long enough to scroll: a summary and three questions.
        static let longSummary = """
            The guard on agent sessions blocks writes outside the workbench folder, but an agent can still rewrite \
            its own .mcp.json and hooks file, and those decide which tools it gets and which checks run. \
            This ask settles three things before the guard ships: whether such writes are queued for you, \
            how long a queued write waits, and what happens to the writes an agent made before the guard.
            """
        static let longPayload = #"{"questions":["#
            + #"{"id":"a","question":"Queue the agent's writes to its own settings?","options":["#
            + #"{"label":"Yes, queue them","description":"The agent cannot lift its own guard from a shell; "#
            + #"normal work is not affected","recommended":true},"#
            + #"{"label":"No, keep as is","description":"Log it as an accepted risk"}]},"#
            + #"{"id":"b","question":"How long does a queued write wait for you?","options":["#
            + #"{"label":"Until you answer","description":"The agent works on; the write lands when you approve it","recommended":true},"#
            + #"{"label":"One day","description":"After a day the write is dropped and the agent is told"},"#
            + #"{"label":"One hour","description":"Short; most writes would be dropped overnight"}]},"#
            + #"{"id":"c","question":"What about the writes made before the guard?","options":["#
            + #"{"label":"List them once","description":"One ask with every change since the workbench was made","recommended":true},"#
            + #"{"label":"Leave them","description":"Only new writes are queued"}]}]}"#
    }
}

/// One shot's world: a workbench with three open asks, its view model wired
/// to an embedded chat center over a scripted AI service and a fake tower.
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
    private let release: AsyncStream<Void>.Continuation
    /// The finding shot's open, held at `chat.new` until `cleanUp`.
    var openTask: Task<Void, Never>?

    init(gateLimit: Int, holdChatNew: Bool, long: Bool = false) throws {
        (pool, path) = try TestDatabase.createPool()
        (writes, tower) = FakeChatTower.writes(pool)
        let (stream, release) = AsyncStream<Void>.makeStream()
        self.release = release
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
            let ask = try TestDatabase.insertOwnerAsk(db, projectID: id, sessionID: session.id, title: sample.title,
                                                      payload: long ? sample.longPayload : sample.payload)
            if long {
                try db.execute(sql: "UPDATE owner_asks SET summary = ? WHERE id = ?", arguments: [sample.longSummary, ask])
            }
            for title in ["Rename the acme_auth package now or after the release?", "Run the migration on the shared database now?"] {
                _ = try TestDatabase.insertOwnerAsk(db, projectID: id, sessionID: session.id, title: title,
                                                    payload: sample.payload)
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

    /// The explanation, then `turns` follow-ups and their answers, as stored
    /// rows: opening such a chat starts nothing.
    func store(_ ask: OwnerAsk, turns: Int) async throws {
        let conversationID = try await AskExplainSurface.conversationID(ask: ask, item: .question(1), dbPool: pool, writes: writes)
        let sample = AskExplainBuiltShotFixtures.Sample.self
        try await pool.write { db in
            let start = Date().timeIntervalSince1970 - 600
            var parent = try TestDatabase.insertChatMessage(db, conversationID: conversationID, role: "assistant",
                                                            text: sample.explanation, createdAt: start)
            for (index, turn) in sample.followUps.prefix(turns).enumerated() {
                let at = start + Double(index + 1) * 60
                parent = try TestDatabase.insertChatMessage(db, conversationID: conversationID, role: "user",
                                                            text: turn.question, parentID: parent, createdAt: at)
                parent = try TestDatabase.insertChatMessage(db, conversationID: conversationID, role: "assistant",
                                                            text: turn.answer, parentID: parent, createdAt: at + 20)
            }
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

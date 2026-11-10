import AppKit
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Branch review's reviewer (board #1025, mockup frame 5): Deep · Chapters
/// with the panel on the Reviewer side — a cross-chapter answer sent to the
/// author, then a failed turn with Retry — and the same panel on the Author
/// side. Turns run through a scripted provider, as a real one would.
@MainActor
enum ReviewerShotFixtures {
    private struct Built {
        let fixture: ReviewFixture
        let identity: ReviewSessionIdentity
        let vm: WorkbenchesViewModel
    }

    private static var built: [String: Built] = [:]
    private static var sideKeys: Set<String> = []

    static func cleanUp() {
        built.values.forEach { $0.fixture.cleanUp() }
        built = [:]
        sideKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        sideKeys = []
    }

    static let files: [ReviewFixture.File] = [
        .init(path: "internal/providers/capabilities.go", additions: 212, deletions: 148),
        .init(path: "internal/providers/registry.go", additions: 96, deletions: 40),
        .init(path: "internal/providers/fallback.go", additions: 18, deletions: 6),
        .init(path: "internal/auth/provider_tokens.go", additions: 64, deletions: 12),
        .init(path: "internal/usage/meter.go", additions: 40, deletions: 8),
        .init(path: "go.sum", additions: 12, deletions: 12, collapsed: "lockfile")
    ]

    static let answer = """
    Three places, one of them easy to miss:

    1. A row in the capability table — `internal/providers/capabilities.go:26-48`. Tiers, tools and attachments come from it now.
    2. A client behind the `Provider` interface and its registration — `internal/providers/registry.go:61-74`.
    3. The fallback chain is a fixed list, not read from the table — `internal/providers/fallback.go:18`. \
    A new provider is never a fallback until it is added there too. (Chapter "internal/providers".)

    The token store keys by provider name (`internal/auth/provider_tokens.go:22`), so it needs no change.
    """

    private static let risks = """
    {"summary":"Providers come from one capability table; the fallback chain stays a fixed list.",
     "coverage":[], "out_of_scope":[],
     "risk":[{"path":"internal/providers/capabilities.go","level":"high","why":"SupportsTools is removed"}],
     "chapters":[]}
    """

    private static func worktree() -> SessionPlace {
        .worktree(name: "provider-registry", root: URL(fileURLWithPath: "/tmp/acme-provider-registry"),
                  status: WorkbenchGitStatus(branch: "feature/provider-registry", dirty: false))
    }

    /// Turns the main run loop until `done` holds (10 s at most).
    private static func spin(_ done: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(done(), "the reviewer fixture did not settle in time")
    }

    private static func make(status: String) throws -> Built {
        let fixture = try ReviewFixture(files: files, status: status, mode: "deep", phase: "chapters", overview: risks)
        fixture.openNow()
        spin { fixture.model.overview != .loading && fixture.model.overview != .idle }
        let identity = fixture.identity(place: worktree())
        let defaults = try XCTUnwrap(UserDefaults(suiteName: DesignShotFixtures.defaultsSuite))
        let vm = WorkbenchesViewModel(dbPool: fixture.pool, cli: nil, defaults: defaults)
        let ai = ScriptedAIService()
        let chats = EmbeddedChatCenter { spec, gate in
            makeSurfaceEngine(spec, dbPool: fixture.pool, ai: ai, gate: gate)
        }
        let center = ReviewerCenter(embeddedChats: chats, dbPool: fixture.pool) { .claudeTools }
        vm.reviewer = center

        let context = try XCTUnwrap(ReviewerSurface.context(
            projectID: fixture.projectID, sessionID: fixture.session.id, round: fixture.model.round,
            place: identity.place, mainStatus: nil))
        let id = ReviewerCenter.ThreadID(projectID: context.projectID, branch: context.branch)
        var opened = false
        Task { @MainActor in
            await center.open(id)
            opened = true
        }
        spin { opened }
        guard case let .ready(conversationID) = center.threads[id] else {
            throw XCTSkip("the reviewer thread did not open")
        }
        let model = fixture.model
        let engine = center.engine(context: context, conversationID: conversationID) { model.reviewerMapInput }

        engine.send("What would adding another provider take?")
        spin { ai.calls.count == 1 }
        ai.emit(.text(answer), .turnComplete(answer), .done)
        ai.finish()
        spin { !engine.isBusy }
        if status == "open", let reply = engine.messages.last {
            var sent = false
            Task { @MainActor in
                await center.send(messageID: reply.id, text: reply.message.text, to: model)
                sent = true
            }
            spin { sent }
        }
        engine.send("What breaks if the table has no row for a provider?")
        spin { ai.calls.count == 2 }
        ai.emit(.error("The reviewer did not answer in 3 min."), .done)
        ai.finish()
        spin { !engine.isBusy }
        return Built(fixture: fixture, identity: identity, vm: vm)
    }

    private static func pane(_ key: String, side: ReviewChatSide, status: String = "open") -> AnyView {
        do {
            if built[key] == nil { built[key] = try make(status: status) }
            guard let entry = built[key] else { return AnyView(EmptyView()) }
            let chat = ReviewAgentChat(vm: entry.vm, projectID: entry.fixture.projectID, sessionID: entry.fixture.session.id)
            // The pane reads the switch from the standard defaults, as in the app.
            UserDefaults.standard.set(side.rawValue, forKey: chat.sideKey)
            sideKeys.insert(chat.sideKey)
            return AnyView(ReviewChangesPaneView(model: entry.fixture.model, identity: entry.identity, chat: chat)
                .detailBackground())
        } catch {
            XCTFail("reviewer shot fixture failed: \(error)")
            return AnyView(Text("fixture failed: \(String(describing: error))").foregroundStyle(.red))
        }
    }

    /// Frame 5: the Reviewer side with an answer sent to the author and a failed turn with Retry.
    static func reviewer() -> AnyView { pane("reviewer", side: .reviewer) }

    /// Frame 5's switch on the Author side: the session's Workchat place, unchanged.
    static func author() -> AnyView { pane("reviewer", side: .author) }

    /// No open round (the round was sent): Send to author is off with "Start a round to send".
    static func noRound() -> AnyView { pane("reviewer-sent", side: .reviewer, status: "sent") }
}

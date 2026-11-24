import AppKit
import ChatUI
import DesignKit
import SwiftUI
import WatchtowerChatText
import WatchtowerCore
@testable import WatchtowerDesktop

/// The Workchat polish spec's states (#2201) on the built pane, `workchat-polish-real-NN-…` beside each mockup
/// `workchat-polish-NN-…` (T8). Laid out as `SessionChatView` lays it out — feed or first-read state, live line,
/// hairline, composer — over the mock's copy and clock. The states other lanes already shot are not drawn again:
/// 04 (`WorkchatHighlightShotFixtures`), 05 (`WorkchatAgentFinishedShotFixtures`), 08 and 09
/// (`WorkchatHeldLineShotFixtures`). The paperclip's menu (06) is an `NSMenu`, which an offscreen render cannot open:
/// 06 is the pane under it, its titles are `ComposerPasteMenu`'s.
@MainActor
enum WorkchatPolishRealShotFixtures {
    static let shots: [DesignShot] = [
        shot("01-steps-collapsed", WorkchatPolishRealShot.State(steps: .collapsed)),
        shot("02-steps-expanded", WorkchatPolishRealShot.State(steps: .expanded)),
        shot("03-steps-narrow", WorkchatPolishRealShot.State(steps: .expanded), width: 340),
        shot("06-paste-menu", WorkchatPolishRealShot.State()),
        DesignShot(name: "workchat-polish-real-07-pasted", prepare: {
            AnyView(WorkchatPolishRealShot(state: .init(), model: try await pastedModel()))
        }, size: NSSize(width: 720, height: 480)),
        shot("10-empty", WorkchatPolishRealShot.State(pane: .empty), height: 360),
        shot("11-loading", WorkchatPolishRealShot.State(pane: .loading), height: 360),
        shot("12-error", WorkchatPolishRealShot.State(pane: .error), height: 360)
    ]

    private static func shot(
        _ name: String, _ state: WorkchatPolishRealShot.State, width: CGFloat = 720, height: CGFloat = 480
    ) -> DesignShot {
        DesignShot(name: "workchat-polish-real-\(name)", size: NSSize(width: width, height: height)) {
            AnyView(WorkchatPolishRealShot(state: state, model: model()))
        }
    }

    /// The shots' clock: every timer reads from it.
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let paneKey = "session-1"

    static func model(attachmentStore: WorkchatAttachmentStore? = nil) -> WorkchatModel {
        WorkchatModel(sessionID: 1, control: PolishShotControl(), lineDelivery: SessionLineDelivery(terminalCenter: nil),
                      attachmentStore: attachmentStore, kind: { .claude }, now: { now })
    }

    /// Mock 07: a pasted screenshot and a long text as inline tokens around typed text, a Finder file as a chip.
    private static func pastedModel() async throws -> WorkchatModel {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("workchat-polish-real-07")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = model(attachmentStore: WorkchatAttachmentStore(root: folder.appendingPathComponent("store")))
        let png = NSImage(size: NSSize(width: 4, height: 4)).tiffRepresentation ?? Data([0])
        let image = await model.paste(.image(png, name: "screenshot.png")) ?? ""
        let longText = (1...212).map { "--- FAIL: TestGate/step_\($0)" }.joined(separator: "\n")
        let text = await model.paste(.text(longText)) ?? ""
        let log = folder.appendingPathComponent("gate.log")
        try Data(count: 84 * 1024).write(to: log)
        model.attach(files: [log])
        model.draft = "\(image) \(WorkchatPolishCopy.pastedText) \(text)"
        return model
    }

    /// The live snapshot of mock 01–03: six steps of 41 (the running Bash at the bottom), one working agent, the
    /// turn 36:34 in.
    static var snapshot: SessionFeedLive {
        var end = now
        var steps: [SessionLiveAction] = []
        for step in WorkchatPolishCopy.steps.reversed() {
            let start = end - seconds(step.time)
            // The host's SendMessage summary is the recipient; the label adds "Message to".
            let summary = step.symbol == "paperplane" ? String(step.summary.dropFirst("Message to ".count)) : step.summary
            steps.append(SessionLiveAction(id: "step-\(step.id)", tool: tool(step.symbol), summary: summary,
                                           startedAt: start, completedAt: step.running ? nil : end))
            end = start
        }
        steps.reverse()
        let agent = SessionLiveAgent(
            ref: SessionFeedSubagent(toolUseID: "toolu_codex", type: "general-purpose",
                                     description: "Codex verify round 3 #2188", status: "running"),
            startedAt: now - 41, canOpen: true)
        return SessionFeedLive(observedAt: now - 1, conversation: "conversation-1", turnAt: now - seconds(WorkchatPolishCopy.turnClock),
                               current: steps.last, agents: [agent], steps: steps,
                               stepsMore: 41 - WorkchatPolishCopy.steps.count)
    }

    static var entries: [SessionFeedEntry] {
        WorkchatPolishCopy.dialog.enumerated().map { index, line in
            SessionFeedEntry(id: "e\(index)", kind: line.owner ? "owner" : "agent",
                             at: now - TimeInterval(300 - 60 * index), text: line.text)
        }
    }

    private static func tool(_ symbol: String) -> String {
        switch symbol {
        case "person.2": "Agent"
        case "doc.text": "Read"
        case "paperplane": "SendMessage"
        default: "Bash"
        }
    }

    /// "3:34" → 214 s; "<1s" → 0.5 s.
    private static func seconds(_ text: String) -> TimeInterval {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : 0.5
    }
}

/// A Workchat control that reads nothing and sends nothing.
private final class PolishShotControl: WorkchatControl {
    func lineCheck(_ sessionID: Int64) -> SessionControl.LineCheck { .go }
    func workchatLineCheck(_ sessionID: Int64) -> SessionControl.LineCheck { .go }
    func isWorking(_ sessionID: Int64) -> Bool { false }
    func interrupt(_ sessionID: Int64) async throws -> SessionControl.InterruptResult { .notWorking }
    func pendingPermission(_ sessionID: Int64) async throws -> SessionControl.PermissionPrompt? { nil }
    func answerPermission(requestID: Int64, sessionID: Int64, allow: Bool, decidedBy: String) async throws
        -> SessionControl.PermissionAnswer { .notFound }
}

/// The Workchat pane on the built views, as `SessionChatView` lays it out: the feed (or the first-read state in its
/// place), the live line with the steps list over it, a hairline, the composer.
@MainActor
struct WorkchatPolishRealShot: View {
    struct State {
        enum Steps { case idle, collapsed, expanded }
        enum Pane { case feed, empty, loading, error }
        var steps: Steps = .idle
        var pane: Pane = .feed
    }

    let state: State
    @SwiftUI.State private var memory: WorkchatPaneMemory
    @SwiftUI.State private var model: WorkchatModel

    init(state: State, model: WorkchatModel) {
        self.state = state
        let memory = WorkchatPaneMemory()
        // Closed by default (#2201 §1); the expanded frames are the owner's toggle.
        if state.steps == .expanded { memory.toggleSteps(WorkchatPolishRealShotFixtures.paneKey) }
        _memory = SwiftUI.State(initialValue: memory)
        _model = SwiftUI.State(initialValue: model)
    }

    private var now: Date { WorkchatPolishRealShotFixtures.now }
    private var working: Bool { state.steps != .idle }

    var body: some View {
        VStack(spacing: 0) {
            switch state.pane {
            case .feed: feed
            case .empty: SessionChatEmptyView()
            case .loading: SessionChatLoadingView()
            case .error: SessionChatErrorBlock(detail: WorkchatPolishCopy.errorDetail) {}
            }
            WorkchatLiveLine(snapshot: working ? WorkchatPolishRealShotFixtures.snapshot : nil, error: nil,
                             loaded: true, working: working,
                             stateAt: now - 72, done: [], paneKey: WorkchatPolishRealShotFixtures.paneKey,
                             memory: memory, feedLoaded: state.pane != .loading,
                             feedError: state.pane == .error ? WorkchatPolishCopy.errorDetail : nil,
                             onRetry: {}, onOpenAgent: { _ in }, referenceDate: now)
            Divider()
            WorkchatComposer(model: model, working: working)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .detailBackground()
    }

    private var feed: some View {
        let workchatFeed = WorkchatFeed(entries: WorkchatPolishRealShotFixtures.entries, markdown: SessionFeedMarkdownCache(),
                                        expandedEvents: []) { _ in }
        var context = workchatFeed.context()
        var follow = ChatFeedFollow(conversationID: 1)
        follow.anchorsBottom = true
        context.follow = follow
        return ChatUI.ChatFeedView(messages: workchatFeed.messages, context: context)
            .macChatStyle(hooks: .app, look: .workchat)
    }
}

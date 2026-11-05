import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// Mockups of the tuning chat beside the Analytics pane (board #1517, spec
/// `2026-11-03-tuning-chat-design.md` §3 and §4.4). Proposal only: the
/// panel, its feed rows and the A/B card are test-target mock views; the
/// coach card in the feed, the pane's coach sections and the Statistics
/// blocks are the real views on fixture data. Everything is synthetic.
@MainActor
enum TuningChatShotFixtures {
    enum State: String, CaseIterable {
        case empty, loading, streaming, error, proposal
        case proposalAccepting = "proposal-accepting", proposalAccepted = "proposal-accepted"
        case proposalStale = "proposal-stale"
        case abProposed = "ab-proposed", abRunning = "ab-running", abDone = "ab-done", abFailed = "ab-failed"
        case abTooFew = "ab-too-few", noTools = "no-tools", narrow
        /// The provider switched to ollama mid-conversation (§4.1): the open card keeps its buttons.
        case noToolsMidway = "no-tools-midway"
        /// §4.6 owner buttons and removal: a discarded card folds, a card whose
        /// inputs were removed reads the removed line, Propose refused, and a
        /// conversation removed with the inputs it read.
        case abDiscarded = "ab-discarded", abRemoved = "ab-removed"
        case abProposeRefused = "ab-propose-refused", conversationRemoved = "conversation-removed"
        /// Retry (or Run) refused because the prompt changed since the run: Discard only.
        case abRunRefused = "ab-run-refused"

        /// Which fixture coach backs the state.
        var coachVariant: String {
            switch self {
            case .proposalStale: "stale"
            case .proposalAccepting: "accepting"
            case .proposalAccepted: "accepted"
            default: "open"
            }
        }
    }

    private static var centers: [String: CoachCenter] = [:]
    static let widthKeys = ["designShots.tuningPanelWidth.460", "designShots.tuningPanelWidth.360"]

    static func cleanUp() {
        centers.values.forEach { $0.stop() }
        centers = [:]
        widthKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    static var shots: [DesignShot] {
        let panes = State.allCases.map { state in
            DesignShot(name: "tuning-chat-\(state.rawValue)",
                       size: NSSize(width: state == .narrow ? 820 : 1040, height: state == .narrow ? 1200 : 800)) {
                screen(state)
            }
        }
        return panes + [
            DesignShot(name: "tuning-chat-analytics-header", size: NSSize(width: 900, height: 58)) {
                AnyView(TuningAnalyticsHeader(tuneOn: false)
                    .padding(Spacing.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .detailBackground())
            },
            DesignShot(name: "tuning-chat-statistics-claude-only", size: NSSize(width: 900, height: 590)) {
                statistics()
            },
            DesignShot(name: "tuning-chat-codex-unread", size: NSSize(width: 900, height: 590)) {
                statistics(codexUnread: true)
            }
        ]
    }

    static func screen(_ state: State) -> AnyView {
        do {
            return AnyView(TuningPaneShot(state: state, coach: try loaded(state.coachVariant)))
        } catch {
            return DesignShotFixtures.failure(error)
        }
    }

    /// The Statistics blocks with Codex sessions in the period: the blocks
    /// that read Claude Code facts only say so (§4.7).
    static func statistics(codexUnread: Bool = false) -> AnyView {
        do {
            let overview = try JSONDecoder().decode(AgentReportOverview.self, from: fixture("agent-report-overview"))
            let actions = AgentAnalyticsActions(turnOn: {}, openSession: { _ in }, openTarget: { _ in },
                                                openFile: { _ in }, openAsks: {}, discuss: { _ in }, asksWaiting: false)
            return AnyView(VStack(alignment: .leading, spacing: Spacing.page) {
                TuningAnalyticsHeader(tuneOn: false)
                SectionHeader(title: "Statistics", systemImage: "chart.bar")
                if codexUnread {
                    Text(TuningChatTexts.codexUnread)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                AgentAnalyticsContextView(context: overview.context, actions: actions).claudeOnly()
                AgentAnalyticsSkillsView(skills: overview.skills).claudeOnly()
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(Spacing.large)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .detailBackground())
        } catch {
            return DesignShotFixtures.failure(error)
        }
    }

    nonisolated private static func fixture(_ name: String) throws -> Data {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: tests.appendingPathComponent("Core/Fixtures/\(name).json"))
    }

    // MARK: - Coach fixture

    /// One center per card variant: `stale` fails its Accept with the CLI's
    /// stale code, `accepting` never returns from it (the card stays
    /// pending), `accepted` lists the chat's proposal as accepted.
    private static func loaded(_ variant: String) throws -> CoachCenter {
        if let center = centers[variant] { return center }
        let coach = CoachCenter(runner: Runner(variant: variant), interval: .seconds(3600))
        coach.show(workbench: 3, period: .week)
        let deadline = Date().addingTimeInterval(5)
        while coach.status[3]?.value == nil || coach.proposals?.value == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNotNil(coach.proposals?.value, "the coach proposals loaded")
        let id = TuningChatTexts.proposalID
        if variant == "stale" || variant == "accepting" {
            Task { await coach.accept(id, editedText: nil) }
            while Date() < deadline,
                  variant == "stale" ? coach.cardErrors[id] == nil : !coach.pending.contains(id) {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
        }
        centers[variant] = coach
        return coach
    }

    nonisolated static let status = """
    {"ok":true,"period":{"since":"2026-10-27T00:00:00Z","until":"2026-11-03T00:00:00Z"},\
    "metrics":{"corrections":{"value":2.4,"n":9,"known":true,"previous":2.1},\
    "task_hours":{"value":1.9,"n":7,"known":true,"previous":1.6},\
    "task_cost_usd":{"value":2.94,"n":7,"known":true,"previous":2.31},\
    "owner_loop":{"value":0.25,"n":7,"known":true,"previous":0.28},\
    "spec_findings":{"value":6.1,"n":3,"known":true,"previous":6.5},\
    "review_comments":{"value":1.5,"n":2,"known":true,"previous":2.0}},"open":1,"last_run":"2026-11-02T09:10:00Z"}
    """

    /// The chat's proposal (a user skill, workbench 0) and one accepted edit.
    nonisolated static func proposals(chatStatus: String) -> String {
        let decided = chatStatus == "accepted" ? #""2026-11-03T10:05:00Z""# : "null"
        return #"""
        {"ok":true,"proposals":[
        {"id":21,"title":"review-pr: read the diff before whole files",
        "why":"In 9 of 12 review sessions this week the agent read every changed file in full first. Asked in this chat.",
        "destination":"claude_skill_user","skill":"review-pr","workbench_id":0,"prompt_id":"","kind":"replace",
        "metric":"task_cost_usd",
        "before":"2. Read each changed file in full.\n3. Note every finding with file:line.",
        "after":"2. Read the diff first. Open a file in full only when a hunk needs its context.\n3. Note every finding with file:line.",
        "evidence":[{"kind":"chat","ref":"c12"},{"kind":"session","ref":"s41"}],"sources":2,"status":"\#(chatStatus)",
        "created_at":"2026-11-03T10:02:00Z","decided_at":\#(decided),"baseline":null,"verdict":"","verdict_value":null,
        "verdict_at":null,"reverts_id":0,"budget":6400},
        {"id":4,"title":"Spec reviewer: skip naming nits","why":"Seen in several reviews.","destination":"prompt_addition",
        "workbench_id":0,"prompt_id":"review.spec","kind":"add","metric":"spec_findings","before":"",
        "after":"Skip naming nits.","evidence":[],"sources":3,"status":"accepted","created_at":"2026-10-24T09:00:00Z",
        "decided_at":"2026-10-24T09:00:00Z","baseline":null,"verdict":"","verdict_value":null,"verdict_at":null,
        "reverts_id":0,"budget":600}
        ]}
        """#
    }

    private final class Runner: CLIRunnerProtocol, @unchecked Sendable {
        let variant: String

        init(variant: String) { self.variant = variant }

        func run(args: [String]) async throws -> Data {
            switch args.dropFirst().first {
            case "status": return Data(TuningChatShotFixtures.status.utf8)
            case "accept" where variant == "accepting":
                // The press is in flight for the whole render.
                try await Task.sleep(for: .seconds(3600))
                return Data()
            case "accept":
                throw CLIRunnerError.nonZeroExit(code: 1, stderr: #"{"ok":false,"error":"stale","code":"stale"}"#)
            default:
                return Data(TuningChatShotFixtures.proposals(chatStatus: variant == "accepted" ? "accepted" : "open").utf8)
            }
        }

        func run(args: [String], timeout: TimeInterval) async throws -> Data { try await run(args: args) }
        func run(args: [String], stdin: Data) async throws -> Data { try await run(args: args) }
    }
}

private extension View {
    /// The block's scope caption on its title line.
    func claudeOnly() -> some View {
        overlay(alignment: .topTrailing) {
            Text(TuningChatTexts.claudeOnly)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(Spacing.medium)
        }
    }
}

// MARK: - Texts

/// Every visible string of the mockups, as `TuningChatTexts` will own them.
enum TuningChatTexts {
    static let proposalID: Int64 = 21
    static let title = "Tuning"
    static let newChat = "New tuning chat"
    static let figures = "7 days · 23 sessions · 7 tasks · $41.20 · $2.94 per task (was $2.31)"
    static let starters = [
        "Why did cost per task grow?",
        "Sessions re-read the same files: 41 times in 9 sessions",
        "Which prompt costs the most?",
        "Tune a skill"
    ]
    static let loading = "Reading this workbench's analytics…"
    static let placeholder = "Ask about cost, prompts, skills or instructions…"
    static let codexUnread = "2 Codex sessions were not read: too large or damaged."
    static let noTools = "Tuning tools need Claude or Codex — pick one in Settings → AI"
    static let turnError = "The model stopped: overloaded — the service is busy. Nothing was proposed."
    static let accepted = "Accepted · measuring for 14 days"
    static let runRefused = "The prompt changed since this A/B ran — start a new one."
    static let abDiscarded = "A/B discarded · digest.channel"
    static let abRemoved = "This A/B was removed with its source data"
    static let proposeRefused = "Not proposed: with today's additions digest.channel would pass 600 characters."
    static let conversationRemoved = "This conversation was removed with the source data it read. "
        + "Its open proposals were withdrawn; accepted ones stay."
    static let showAccepted = "Show in Accepted edits"
    static let claudeOnly = "Claude Code only"
    static let tooFew = "Only 2 past calls of digest.channel match the current prompt — A/B needs 3. "
        + "It will be possible after the prompt runs again."
    static let skillAsk = "The review-pr skill makes the agent read every changed file. Can we fix that?"
    static let skillAnswer = "In 9 of 12 review sessions the agent opened every changed file in full before "
        + "looking at the diff. Step 2 of your review-pr skill asks for exactly that. Here is a smaller step 2:"
    static let costAsk = "Which prompt costs the most?"
    static let costPartial = "Over the last 7 days, **digest.channel** is the most expensive Watchtower prompt: "
        + "$6.80 in 212 calls. Most of it is input: each call carries the whole"
    static let digestAsk = "Channel digests never say who made a decision. Can a prompt addition fix it?"
    static let digestAnswer = "Yes, with one line in the additions of digest.channel. "
        + "Before you keep it, it can run on the last 5 captured inputs, without and with the line."
    static let tooFewAnswer = "One line in the additions of digest.channel should do it: "
        + "\"When a thread ends in a decision, name who made it.\" I can propose it as an edit now."
}

// MARK: - Pane

/// The Analytics pane and the tuning panel side by side (`PanelSplit`).
private struct TuningPaneShot: View {
    let state: TuningChatShotFixtures.State
    let coach: CoachCenter

    private var width: PanelSplitWidth {
        let narrow = state == .narrow
        return PanelSplitWidth(key: TuningChatShotFixtures.widthKeys[narrow ? 1 : 0],
                               range: 360...720, ideal: narrow ? 360 : 460)
    }

    var body: some View {
        // Own edge line: the split's `Divider()` overlay lies flat in this host.
        PanelSplit(isPanelShown: true, width: width, showsEdgeLine: false) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.page) {
                    TuningAnalyticsHeader(tuneOn: true)
                    CoachSectionsView(coach: coach, workbench: 3, actions: TuningFeed.noActions)
                }
                .frame(maxWidth: 900, alignment: .leading)
                .padding(Spacing.large)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .detailBackground()
        } panel: {
            TuningPanelShot(state: state, coach: coach)
                .background(Color(nsColor: .windowBackgroundColor))
                .overlay(alignment: .leading) {
                    Rectangle().fill(.separator).frame(width: Stroke.hairline)
                }
        }
    }
}

/// The pane header (§3.1): the agent filter beside the period, and **Tune**
/// in place of **Discuss in Chat**, on while the panel is open.
struct TuningAnalyticsHeader: View {
    let tuneOn: Bool

    enum Agent: Hashable { case all, claude, codex }

    var body: some View {
        // One row when the pane is wide; the controls drop under the period
        // when the tuning panel leaves the pane narrow.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Spacing.regular) {
                period
                Spacer(minLength: Spacing.regular)
                controls
            }
            VStack(alignment: .leading, spacing: Spacing.regular) {
                period
                HStack(spacing: Spacing.regular) {
                    agentPicker
                    periodControls
                }
            }
            VStack(alignment: .leading, spacing: Spacing.regular) {
                period
                agentPicker
                periodControls
            }
        }
        .controlSize(.small)
    }

    private var period: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Text("Oct 27 – Nov 3").font(.headline)
            Text("against Oct 20 – 27").font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    private var controls: some View {
        HStack(alignment: .center, spacing: Spacing.regular) {
            agentPicker
            periodControls
        }
    }

    private var agentPicker: some View {
        KitSegmentedPicker(title: "Agent", selection: .constant(Agent.all), segments: [
            KitSegment(value: Agent.all, title: "All"),
            KitSegment(value: Agent.claude, title: "Claude Code"),
            KitSegment(value: Agent.codex, title: "Codex")
        ])
        .fixedSize()
    }

    private var periodControls: some View {
        HStack(alignment: .center, spacing: Spacing.regular) {
            KitSegmentedPicker(title: "Period", selection: .constant(AgentAnalyticsCenter.Period.week), segments: [
                KitSegment(value: AgentAnalyticsCenter.Period.day, title: "1 day"),
                KitSegment(value: AgentAnalyticsCenter.Period.week, title: "7 days"),
                KitSegment(value: AgentAnalyticsCenter.Period.month, title: "30 days")
            ])
            Circle()
                .fill(Tone.success)
                .frame(width: IconSize.stateDot, height: IconSize.stateDot)
            Toggle(isOn: .constant(tuneOn)) { Label("Tune", systemImage: "slider.horizontal.3") }
                .toggleStyle(SegmentedToggleStyle(isHovered: false) { _ in })
                .segmentCapsule()
                .help("Tune prompts, skills and agent instructions in a chat")
        }
        .fixedSize()
    }
}

// MARK: - Panel

/// Title row, feed, composer.
private struct TuningPanelShot: View {
    let state: TuningChatShotFixtures.State
    let coach: CoachCenter

    private var isFresh: Bool { [.empty, .loading, .noTools].contains(state) }
    private var busy: Bool { state == .streaming }

    var body: some View {
        VStack(spacing: 0) {
            titleRow
            ScrollView {
                TuningFeed(state: state, coach: coach)
                    .padding(.horizontal, Spacing.medium)
                    .padding(.vertical, Spacing.regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(isFresh ? .top : .bottom)
            if state == .noToolsMidway {
                TuningFeed.noToolsCard
                    .padding(.horizontal, Spacing.medium)
                    .padding(.bottom, Spacing.regular)
            }
            composer
        }
    }

    private var titleRow: some View {
        HStack(spacing: Spacing.regular) {
            Text(TuningChatTexts.title).font(.headline)
            MenuLabel(text: isFresh ? TuningChatTexts.newChat : conversation,
                      systemImage: "bubble.left.and.bubble.right", color: .secondary)
                .lineLimit(1)
            Spacer(minLength: Spacing.regular)
            Button("New") {}.buttonStyle(.kitQuiet)
            Button {} label: { Image(systemName: "xmark") }
                .buttonStyle(.kitIcon(isOn: false))
                .help("Close (Esc)")
        }
        .controlSize(.small)
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.regular)
    }

    private var conversation: String {
        switch state {
        case .streaming, .error: "Which prompt costs the most?"
        case .proposal, .proposalAccepting, .proposalAccepted, .proposalStale, .noToolsMidway:
            "review-pr reads every file"
        default: "Digests miss the decision owner"
        }
    }

    private var composer: some View {
        HStack(spacing: Spacing.compact) {
            Text(TuningChatTexts.placeholder).foregroundStyle(.tertiary).lineLimit(1)
            Spacer(minLength: Spacing.compact)
            Image(systemName: busy ? "stop.fill" : "arrow.up")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: IconSize.composerLarge, height: IconSize.composerLarge)
                .help(busy ? "Stop" : "Send")
        }
        .font(.callout)
        .padding(Spacing.cozy)
        .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.control))
        .padding(.horizontal, Spacing.medium)
        .padding(.bottom, Spacing.medium)
    }
}

// MARK: - Feed

private struct TuningFeed: View {
    let state: TuningChatShotFixtures.State
    let coach: CoachCenter

    static let noActions = CoachActions(openAsk: { _ in }, openTerminalSession: { _ in }, scrollToStatistics: {})

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            switch state {
            case .empty: fresh(starters: true)
            case .loading:
                HStack(spacing: Spacing.compact) {
                    ProgressView().controlSize(.small)
                    Text(TuningChatTexts.loading).font(.callout).foregroundStyle(.secondary)
                }
            case .noTools: fresh(starters: false); Self.noToolsCard
            case .noToolsMidway: fresh(starters: false); skillTurn(folded: false)
            case .streaming: streaming
            case .error: turnError
            case .proposal, .proposalAccepting, .proposalStale: skillTurn(folded: false)
            case .proposalAccepted: skillTurn(folded: true)
            case .abProposed: replayTurn(.proposed)
            case .abRunning: replayTurn(.running)
            case .abDone: replayTurn(.done)
            case .abFailed: replayTurn(.failed)
            case .abDiscarded: replayTurn(nil, line: (TuningChatTexts.abDiscarded, "xmark.circle", .secondary))
            case .abRemoved: replayTurn(nil, line: (TuningChatTexts.abRemoved, "trash", .secondary))
            case .abProposeRefused: replayTurn(.proposeRefused)
            case .abRunRefused: replayTurn(.runRefused)
            case .conversationRemoved: conversationRemoved
            case .abTooFew: tooFew
            case .narrow:
                skillTurn(folded: false)
                replayTurn(.done, stacked: true)
            }
        }
    }

    @ViewBuilder private func fresh(starters: Bool) -> some View {
        Text(TuningChatTexts.figures).font(.caption).foregroundStyle(.secondary)
        if starters {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                ForEach(TuningChatTexts.starters, id: \.self) { starter in
                    Button {} label: {
                        HStack(spacing: Spacing.regular) {
                            Image(systemName: "text.bubble").foregroundStyle(.secondary)
                            Text(starter).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .font(.callout)
                        .padding(.horizontal, Spacing.cozy)
                        .padding(.vertical, Spacing.regular)
                        .background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.row))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    static var noToolsCard: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Label(TuningChatTexts.noTools, systemImage: "wrench.and.screwdriver")
                .font(.callout)
            Text("Without them the chat can talk, but it cannot read the report, prompts or skills, or propose an edit.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open Settings") {}.buttonStyle(.kitSecondary)
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ViewBuilder private var streaming: some View {
        UserMessageBubble(text: TuningChatTexts.costAsk)
        TuningToolLines(lines: [("Read the 7-day LLM usage", false), ("Read prompt digest.channel", false),
                                ("Listing captured inputs of digest.channel…", true)])
        MarkdownView(text: TuningChatTexts.costPartial)
        StreamingIndicator()
    }

    @ViewBuilder private var turnError: some View {
        UserMessageBubble(text: TuningChatTexts.costAsk)
        TuningToolLines(lines: [("Read the 7-day LLM usage", false)])
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Label(TuningChatTexts.turnError, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(Tone.error)
            Spacer(minLength: Spacing.regular)
            Button("Retry") {}.buttonStyle(.kitSecondary)
        }
    }

    @ViewBuilder private func skillTurn(folded: Bool) -> some View {
        UserMessageBubble(text: TuningChatTexts.skillAsk)
        TuningToolLines(lines: [("Read skill review-pr", false), ("Read 12 sessions of the last 7 days", false),
                                ("Read the coach's proposals", false), ("Proposed an edit to review-pr", false)])
        Text(TuningChatTexts.skillAnswer)
        if folded {
            acceptedLine
        } else if let proposal = coach.proposals?.value?.first(where: { $0.id == TuningChatTexts.proposalID }) {
            CoachProposalCardView(proposal: proposal, isFirst: false, coach: coach, actions: Self.noActions) {}
        }
    }

    /// An accepted proposal folds to one line; the pane's Accepted edits holds the rest.
    private var acceptedLine: some View {
        HStack(spacing: Spacing.compact) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Tone.success)
            Text(TuningChatTexts.accepted).font(.callout).lineLimit(1)
            Spacer(minLength: Spacing.regular)
            Button(TuningChatTexts.showAccepted) {}.buttonStyle(.kitQuiet).font(.callout)
        }
        .padding(.horizontal, Spacing.cozy)
        .padding(.vertical, Spacing.regular)
        .background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.row))
    }

    @ViewBuilder private var tooFew: some View {
        UserMessageBubble(text: TuningChatTexts.digestAsk)
        TuningToolLines(lines: [("Read prompt digest.channel", false),
                                ("Listed 2 captured inputs of digest.channel", false)])
        Text(TuningChatTexts.tooFewAnswer)
        Label(TuningChatTexts.tooFew, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The whole conversation was deleted with the captured inputs it read (§4.5).
    @ViewBuilder private var conversationRemoved: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Label(TuningChatTexts.conversationRemoved, systemImage: "trash")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(TuningChatTexts.newChat) {}.buttonStyle(.kitSecondary)
        }
        .padding(Spacing.cozy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.row))
    }

    /// A one-line replay row in place of the card.
    private func foldedLine(_ line: (String, String, Color)) -> some View {
        HStack(spacing: Spacing.compact) {
            Image(systemName: line.1).foregroundStyle(line.2)
            Text(line.0).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.cozy)
        .padding(.vertical, Spacing.regular)
        .background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.row))
    }

    @ViewBuilder private func replayTurn(
        _ phase: TuningReplayCard.Phase?,
        line: (String, String, Color)? = nil,
        stacked: Bool = false
    ) -> some View {
        UserMessageBubble(text: TuningChatTexts.digestAsk)
        TuningToolLines(lines: [("Read prompt digest.channel", false),
                                ("Listed 5 captured inputs of digest.channel", false),
                                ("Proposed a replay on 5 past calls", false)])
        Text(TuningChatTexts.digestAnswer)
        if let phase {
            TuningReplayCard(phase: phase, stacked: stacked)
        } else if let line {
            foldedLine(line)
        }
    }
}

/// Quiet tool-activity lines (§3.4): a check when done, a spinner on the live one.
private struct TuningToolLines: View {
    let lines: [(String, Bool)]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: Spacing.compact) {
                    if line.1 {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "checkmark").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Text(line.0).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

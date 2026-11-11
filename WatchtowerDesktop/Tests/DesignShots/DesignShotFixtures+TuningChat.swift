import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// Mockups of the tuning chat beside the Analytics pane (board #1517, spec
/// `2026-11-03-tuning-chat-design.md` §3, §4.3a and §4.4). Proposal only: the
/// panel and its feed rows are test-target mock views; the
/// coach card in the feed, the pane's coach sections and the Statistics
/// blocks are the real views on fixture data. Everything is synthetic.
@MainActor
enum TuningChatShotFixtures {
    enum State: String, CaseIterable {
        case empty, loading, streaming, error, proposal
        case proposalAccepting = "proposal-accepting", proposalAccepted = "proposal-accepted"
        case proposalStale = "proposal-stale"
        /// An accepted edit of the workbench folder's CLAUDE.md (§4.3a, ask #1165):
        /// the folded line says the file was written and the owner commits it.
        case proposalAcceptedRepo = "proposal-accepted-repo"
        case noTools = "no-tools", narrow
        /// The provider switched to ollama mid-conversation (§4.1): the open card keeps its buttons.
        case noToolsMidway = "no-tools-midway"

        /// Which fixture coach backs the state.
        var coachVariant: String {
            switch self {
            case .proposalStale: "stale"
            case .proposalAccepting: "accepting"
            case .proposalAccepted: "accepted"
            case .proposalAcceptedRepo: "accepted-repo"
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
                       size: size(state)) {
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
            DesignShot(name: "tuning-chat-statistics-codex-caption", size: NSSize(width: 900, height: 590)) {
                statistics()
            }
        ]
    }

    private static func size(_ state: State) -> NSSize {
        switch state {
        case .narrow: NSSize(width: 820, height: 1200)
        default: NSSize(width: 1040, height: 800)
        }
    }

    static func screen(_ state: State) -> AnyView {
        do {
            return AnyView(TuningPaneShot(state: state, coach: try loaded(state.coachVariant)))
        } catch {
            return DesignShotFixtures.failure(error)
        }
    }

    /// The Statistics blocks with Codex sessions in the period: the Context
    /// and Skills blocks carry main's caption "Not measured for Codex
    /// sessions." (§4.7, ask #1132).
    static func statistics() -> AnyView {
        do {
            let overview = try JSONDecoder().decode(AgentReportOverview.self, from: fixture("agent-report-overview"))
            let actions = AgentAnalyticsActions(turnOn: {}, openSession: { _ in }, openTarget: { _ in },
                                                openFile: { _ in }, openAsks: {}, tune: {}, asksWaiting: false)
            return AnyView(VStack(alignment: .leading, spacing: Spacing.page) {
                TuningAnalyticsHeader(tuneOn: false)
                SectionHeader(title: "Statistics", systemImage: "chart.bar")
                AgentAnalyticsContextView(context: overview.context, codex: .some, actions: actions)
                AgentAnalyticsSkillsView(skills: overview.skills, codex: .some)
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
        let id = TuningShotTexts.proposalID
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
    /// `accepted-repo` lists only the earlier accepted edit; its folded line
    /// reads `TuningChatTexts.acceptedRepoFile` (the shots move onto the real
    /// views, the repository row with them, in Task 5.13).
    nonisolated static func proposals(chatStatus: String) -> String {
        if chatStatus == "accepted-repo" {
            return #"""
            {"ok":true,"proposals":[
            {"id":4,"title":"Spec reviewer: skip naming nits","why":"Seen in several reviews.","destination":"prompt_addition",
            "workbench_id":0,"prompt_id":"review.spec","kind":"add","metric":"spec_findings","before":"",
            "after":"Skip naming nits.","evidence":[],"sources":3,"status":"accepted","created_at":"2026-10-24T09:00:00Z",
            "decided_at":"2026-10-24T09:00:00Z","baseline":null,"verdict":"","verdict_value":null,"verdict_at":null,
            "reverts_id":0,"budget":600}
            ]}
            """#
        }
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
                let status = ["accepted", "accepted-repo"].contains(variant) ? variant : "open"
                return Data(TuningChatShotFixtures.proposals(chatStatus: status).utf8)
            }
        }

        func run(args: [String], timeout: TimeInterval) async throws -> Data { try await run(args: args) }
        func run(args: [String], stdin: Data) async throws -> Data { try await run(args: args) }
    }
}

// MARK: - Texts

/// Fixture-only text of the mockups; the panel's own strings live in `TuningChatTexts`.
enum TuningShotTexts {
    static let figuresText = TuningChatTexts.figures(
        .init(days: 7, sessions: 23, tasks: 7, costUSD: 41.2, perTaskUSD: 2.94, previousPerTaskUSD: 2.31)
    )
    static let starterTitles = starterPrompts.map(\.title)
    private static let starterPrompts = TuningChatTexts.starters(
        .init(costPerTaskGrew: true, topHintFinding: "Sessions re-read the same files: 41 times in 9 sessions")
    )
    static let proposalID: Int64 = 21
    static let turnError = "The model stopped: overloaded — the service is busy. Nothing was proposed."
    /// The folded line of an accepted workbench repository file (§4.3a).
    static let acceptedRepo = TuningChatTexts.acceptedRepoFile(path: "CLAUDE.md", branch: "main")
    static let skillAsk = "The review-pr skill makes the agent read every changed file. Can we fix that?"
    static let skillAnswer = "In 9 of 12 review sessions the agent opened every changed file in full before "
        + "looking at the diff. Step 2 of your review-pr skill asks for exactly that. Here is a smaller step 2:"
    static let costAsk = "Which prompt costs the most?"
    static let costPartial = "Over the last 7 days, **digest.channel** is the most expensive Watchtower prompt: "
        + "$6.80 in 212 calls. Most of it is input: each call carries the whole"
    static let repoAsk = "Sessions in this repo keep running the whole test suite. Can CLAUDE.md fix that?"
    static let repoAnswer = "In 7 of 9 sessions the agent ran `go test ./...` after a one-package change. "
        + "Your CLAUDE.md never says which tests to run. I proposed one line under Build & Test: "
        + "\"Run only the touched package's tests while iterating.\""
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
        case .proposalAcceptedRepo: "Tests run the whole suite"
        default: "review-pr reads every file"
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
            case .proposalAcceptedRepo: repoTurn
            case .narrow: skillTurn(folded: false)
            }
        }
    }

    @ViewBuilder private func fresh(starters: Bool) -> some View {
        Text(TuningShotTexts.figuresText).font(.caption).foregroundStyle(.secondary)
        if starters {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                ForEach(TuningShotTexts.starterTitles, id: \.self) { starter in
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
        UserMessageBubble(text: TuningShotTexts.costAsk)
        TuningToolLines(lines: [tool("get_llm_usage", #"{"days":7}"#), ("Reading prompt digest.channel…", true)])
        MarkdownView(text: TuningShotTexts.costPartial)
        StreamingIndicator()
    }

    @ViewBuilder private var turnError: some View {
        UserMessageBubble(text: TuningShotTexts.costAsk)
        TuningToolLines(lines: [tool("get_llm_usage", #"{"days":7}"#)])
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Label(TuningShotTexts.turnError, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(Tone.error)
            Spacer(minLength: Spacing.regular)
            Button("Retry") {}.buttonStyle(.kitSecondary)
        }
    }

    @ViewBuilder private func skillTurn(folded: Bool) -> some View {
        UserMessageBubble(text: TuningShotTexts.skillAsk)
        TuningToolLines(lines: [tool("get_skill", #"{"name":"review-pr"}"#), tool("list_agent_sessions", "{}"),
                                tool("list_coach_proposals", "{}"), tool("propose_tuning_edit", #"{"skill":"review-pr"}"#)])
        Text(TuningShotTexts.skillAnswer)
        if folded {
            acceptedLine(TuningChatTexts.accepted)
        } else if let proposal = coach.proposals?.value?.first(where: { $0.id == TuningShotTexts.proposalID }) {
            CoachProposalCardView(proposal: proposal, isFirst: false, coach: coach, actions: Self.noActions) {}
        }
    }

    /// A chat edit of the workbench folder's CLAUDE.md, accepted (§4.3a): the
    /// file is written and the owner commits it; Watchtower runs no git write.
    @ViewBuilder private var repoTurn: some View {
        UserMessageBubble(text: TuningShotTexts.repoAsk)
        TuningToolLines(lines: [tool("get_agent_instructions", "{}"), tool("list_agent_sessions", "{}"),
                                tool("list_coach_proposals", "{}"), tool("propose_tuning_edit", #"{"name":"CLAUDE.md"}"#)])
        MarkdownView(text: TuningShotTexts.repoAnswer)
        acceptedLine(TuningShotTexts.acceptedRepo)
    }

    /// An accepted proposal folds to one line; the pane's Accepted edits holds the rest.
    private func acceptedLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Tone.success)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.regular)
            Button(TuningChatTexts.showAccepted) {}.buttonStyle(.kitQuiet).font(.callout)
        }
        .padding(.horizontal, Spacing.cozy)
        .padding(.vertical, Spacing.regular)
        .background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.row))
    }
}

/// One finished tool line, worded by the app's own `TuningChatTexts.toolLine`.
private func tool(_ name: String, _ args: String) -> (String, Bool) {
    (TuningChatTexts.toolLine(name: name, args: args) ?? name, false)
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

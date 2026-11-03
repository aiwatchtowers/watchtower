import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// Mockups of the tuning chat over the Analytics pane (board #1517, spec
/// `2026-11-03-tuning-chat-design.md` §3 and §4.4). Proposal only: the
/// panel, its feed rows and the A/B card are test-target mock views; the
/// coach card in the feed and the pane's coach sections are the real views
/// on fixture data. Everything is synthetic (acme, example.com).
@MainActor
enum TuningChatShotFixtures {
    enum State: String, CaseIterable {
        case empty, loading, streaming, error, proposal, proposalStale = "proposal-stale"
        case abProposed = "ab-proposed", abRunning = "ab-running", abDone = "ab-done", abFailed = "ab-failed"
        case noTools = "no-tools", narrow
    }

    private static var centers: [String: CoachCenter] = [:]

    static func cleanUp() {
        centers.values.forEach { $0.stop() }
        centers = [:]
    }

    static var shots: [DesignShot] {
        let panes = State.allCases.map { state in
            DesignShot(name: "tuning-chat-\(state.rawValue)",
                       size: NSSize(width: state == .narrow ? 820 : 1040, height: state == .narrow ? 1180 : 780)) {
                screen(state)
            }
        }
        return panes + [
            DesignShot(name: "tuning-chat-analytics-header", size: NSSize(width: 900, height: 52)) {
                AnyView(TuningAnalyticsHeader()
                    .padding(Spacing.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .detailBackground())
            }
        ]
    }

    static func screen(_ state: State) -> AnyView {
        do {
            let coach = try loaded(state == .proposalStale ? "stale" : "open")
            return AnyView(TuningPaneShot(state: state, coach: coach))
        } catch {
            return DesignShotFixtures.failure(error)
        }
    }

    // MARK: - Coach fixture

    /// One center per card variant: `stale` fails its Accept with the CLI's
    /// stale code, so the real card shows its own error line.
    private static func loaded(_ variant: String) throws -> CoachCenter {
        if let center = centers[variant] { return center }
        let coach = CoachCenter(runner: Runner(), interval: .seconds(3600))
        coach.show(workbench: 3, period: .week)
        let deadline = Date().addingTimeInterval(5)
        while coach.status[3]?.value == nil || coach.proposals?.value == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNotNil(coach.proposals?.value, "the coach proposals loaded")
        if variant == "stale" {
            Task { await coach.accept(TuningChatTexts.proposalID, editedText: nil) }
            while coach.cardErrors[TuningChatTexts.proposalID] == nil, Date() < deadline {
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
    nonisolated static let proposals = #"""
    {"ok":true,"proposals":[
    {"id":21,"title":"review-pr: read the diff before whole files",
    "why":"In 9 of 12 review sessions this week the agent read every changed file in full first. Asked in this chat.",
    "destination":"claude_skill_user","workbench_id":0,"prompt_id":"","kind":"replace","metric":"task_cost_usd",
    "before":"2. Read each changed file in full.\n3. Note every finding with file:line.",
    "after":"2. Read the diff first. Open a file in full only when a hunk needs its context.\n3. Note every finding with file:line.",
    "evidence":[{"kind":"chat","ref":"c12"},{"kind":"session","ref":"s41"}],"sources":2,"status":"open",
    "created_at":"2026-11-03T10:02:00Z","decided_at":null,"baseline":null,"verdict":"","verdict_value":null,
    "verdict_at":null,"reverts_id":0,"budget":6400},
    {"id":4,"title":"Spec reviewer: skip naming nits","why":"Seen in several reviews.","destination":"prompt_addition",
    "workbench_id":0,"prompt_id":"review.spec","kind":"add","metric":"spec_findings","before":"",
    "after":"Skip naming nits.","evidence":[],"sources":3,"status":"accepted","created_at":"2026-10-24T09:00:00Z",
    "decided_at":"2026-10-24T09:00:00Z","baseline":null,"verdict":"","verdict_value":null,"verdict_at":null,
    "reverts_id":0,"budget":600}
    ]}
    """#

    private final class Runner: CLIRunnerProtocol, @unchecked Sendable {
        func run(args: [String]) async throws -> Data {
            switch args.dropFirst().first {
            case "status": return Data(TuningChatShotFixtures.status.utf8)
            case "accept":
                throw CLIRunnerError.nonZeroExit(code: 1, stderr: #"{"ok":false,"error":"stale","code":"stale"}"#)
            default: return Data(TuningChatShotFixtures.proposals.utf8)
            }
        }

        func run(args: [String], timeout: TimeInterval) async throws -> Data { try await run(args: args) }
        func run(args: [String], stdin: Data) async throws -> Data { try await run(args: args) }
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
    static let noTools = "Tuning tools need Claude or Codex — pick one in Settings → AI"
    static let turnError = "The model stopped: overloaded — the service is busy. Nothing was proposed."
    static let skillAsk = "The review-pr skill makes the agent read every changed file. Can we fix that?"
    static let skillAnswer = "In 9 of 12 review sessions the agent opened every changed file in full before "
        + "looking at the diff. Step 2 of your review-pr skill asks for exactly that. Here is a smaller step 2:"
    static let costAsk = "Which prompt costs the most?"
    static let costPartial = "Over the last 7 days, **digest.channel** is the most expensive Watchtower prompt: "
        + "$6.80 in 212 calls. Most of it is input: each call carries the whole"
    static let digestAsk = "Channel digests never say who made a decision. Can a prompt addition fix it?"
    static let digestAnswer = "Yes, with one line in the additions of digest.channel. "
        + "Before you keep it, it can run on the last 5 captured inputs, without and with the line."
}

// MARK: - Pane

/// The Analytics pane with the tuning panel open on its trailing side, as
/// the board's target panel (overlay, leading resize strip, shadow).
private struct TuningPaneShot: View {
    let state: TuningChatShotFixtures.State
    let coach: CoachCenter

    private var panelWidth: CGFloat { state == .narrow ? 360 : 460 }

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(alignment: .leading, spacing: Spacing.page) {
                TuningAnalyticsHeader()
                CoachSectionsView(coach: coach, workbench: 3, actions: TuningFeed.noActions)
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(Spacing.large)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .detailBackground()

            TuningPanelShot(state: state, coach: coach)
                .frame(width: panelWidth)
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                // A vertical hairline: a bare `Divider()` in an overlay lies flat.
                .overlay(alignment: .leading) {
                    Rectangle().fill(.separator).frame(width: Stroke.hairline)
                }
                .compositingGroup()
                .shadow(color: .black.opacity(0.18), radius: 12, x: -2)
                .overlay(alignment: .leading) {
                    PanelResizeHandle(width: .constant(Double(panelWidth)), liveWidth: .constant(nil),
                                      range: 360...720, growsLeftward: true)
                }
        }
    }
}

/// The pane header with **Tune** in place of **Discuss in Chat** (§3.1).
struct TuningAnalyticsHeader: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Text("Oct 27 – Nov 3").font(.headline)
            Text("against Oct 20 – 27").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: Spacing.regular)
            KitSegmentedPicker(title: "Period", selection: .constant(AgentAnalyticsCenter.Period.week), segments: [
                KitSegment(value: AgentAnalyticsCenter.Period.day, title: "1 day"),
                KitSegment(value: AgentAnalyticsCenter.Period.week, title: "7 days"),
                KitSegment(value: AgentAnalyticsCenter.Period.month, title: "30 days")
            ])
            Circle()
                .fill(Tone.success)
                .frame(width: IconSize.stateDot, height: IconSize.stateDot)
            Button {} label: { Label("Tune", systemImage: "slider.horizontal.3") }
                .buttonStyle(.kitSecondary)
                .help("Tune prompts, skills and agent instructions in a chat")
        }
        .controlSize(.small)
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
        case .proposal, .proposalStale: "review-pr reads every file"
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
            case .noTools: noTools
            case .streaming: streaming
            case .error: turnError
            case .proposal, .proposalStale: skillTurn
            case .abProposed: replayTurn(.proposed)
            case .abRunning: replayTurn(.running)
            case .abDone: replayTurn(.done)
            case .abFailed: replayTurn(.failed)
            case .narrow:
                skillTurn
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

    @ViewBuilder private var noTools: some View {
        fresh(starters: false)
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

    @ViewBuilder private var skillTurn: some View {
        UserMessageBubble(text: TuningChatTexts.skillAsk)
        TuningToolLines(lines: [("Read skill review-pr", false), ("Read 12 sessions of the last 7 days", false),
                                ("Read the coach's proposals", false), ("Proposed an edit to review-pr", false)])
        Text(TuningChatTexts.skillAnswer)
        if let proposal = coach.proposals?.value?.first(where: { $0.id == TuningChatTexts.proposalID }) {
            CoachProposalCardView(proposal: proposal, isFirst: false, coach: coach, actions: Self.noActions) {}
        }
    }

    @ViewBuilder private func replayTurn(_ phase: TuningReplayCard.Phase, stacked: Bool = false) -> some View {
        UserMessageBubble(text: TuningChatTexts.digestAsk)
        TuningToolLines(lines: [("Read prompt digest.channel", false),
                                ("Listed 5 captured inputs of digest.channel", false),
                                ("Proposed a replay on 5 past calls", false)])
        Text(TuningChatTexts.digestAnswer)
        TuningReplayCard(phase: phase, stacked: stacked)
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

import AppKit
import DesignKit
import SwiftUI
import WatchtowerCore
@testable import WatchtowerDesktop

/// Workchat agents and live steps spec (#2065), design only: the 👥 list with
/// Working and Done, the live steps disclosure and the feed without agent
/// cards. Static mock data; no production view or model is used or changed.
struct WorkchatAgentsMock {
    struct Agent: Identifiable {
        let id: String
        let type: String
        let task: String
        var tool = ""
        var action = ""
        var elapsed = ""
    }

    struct Step: Identifiable {
        let id: Int
        let tool: String
        let summary: String
        let time: String
        var running = false
    }

    /// A run of the composer's text: plain text or an atomic paste token.
    enum Part: Hashable {
        case text(String)
        case image(String)
        case paste(String)
    }

    enum Badge { case working(Int), done(Int), unknown, none }
    enum List { case closed, agents(doneOpen: Bool), loading, error }

    var badge: Badge
    var list: List
    var working: [Agent] = []
    var done: [Agent] = []
    var steps: [Step] = []
    var stepsOpen = false
    var narrow = false
    /// No turn running: the caption row keeps only the 👥 button.
    var idle = false
    /// The session ended: its "ended" line, then the same caption row, no composer.
    var ended = false
    /// What the owner has typed into the composer (nil: the placeholder).
    var draft: [Part]?
    /// An owner line just sent mid-turn, drawn with its "Queued" caption.
    var queuedLine: String?

    // MARK: - Copy

    static let listTitle = "Agents"
    static let workingTitle = "WORKING"
    static let unknownWorking = "Agent status unavailable"
    static let noneWorking = "No agents working"
    static let loading = "Loading agents…"
    static let error = "Couldn’t read the agents"
    static let retry = "Retry"
    static func doneTitle(_ count: Int) -> String { "Done · \(count)" }
    static let lineText = "go test ./internal/sessionfeed -run TestLiveSteps"
    static let lineMore = "· 7 more"
    static let lineElapsed = "1:12"
    static let placeholder = "Message the agent… (/ for commands)"
    static let endedLine = "Session finished. The history stays readable."
    static let queuedCaption = "Queued · the agent reads it at its next step"

    static let feed: [(owner: Bool, text: String)] = [
        (true, "Recon the DB layer and get a Codex review of the plan."),
        (false, "Two agents are on it: one reads the migrations, the other runs the Codex review. "
            + "I’ll fold both into one summary when they are back."),
        (true, "Also check the lock metrics while you’re there."),
        (false, "Will do. The live steps test is running now; the lock metrics come next.")
    ]
    static let idleReply = "Both agents are back: the migrations are clean, Codex flagged one ordering issue in Task 3. "
        + "The lock metrics show no waits over 200 ms."

    // MARK: - Data

    static let workingAgents = [
        Agent(id: "w1", type: "Explore", task: "Recon the DB layer", tool: "Grep", action: "Grep migrations/", elapsed: "0:48"),
        Agent(id: "w2", type: "codex-wrapper", task: "Codex review of the plan", tool: "Bash", action: "codex review", elapsed: "0:21")
    ]
    static let doneAgents = [
        Agent(id: "d1", type: "codex-wrapper", task: "Review the spec draft"),
        Agent(id: "d2", type: "Explore", task: "Read the phone chat filter"),
        Agent(id: "d3", type: "general-purpose", task: "Measure the open time"),
        Agent(id: "d4", type: "style-guardian", task: "Style pass on Task 2"),
        Agent(id: "d5", type: "Explore", task: "Locate the live line tests"),
        Agent(id: "d6", type: "Plan", task: "Draft the steps model"),
        Agent(id: "d7", type: "codex-wrapper", task: "Review the Task 3 diff"),
        Agent(id: "d8", type: "Explore", task: "Find the subagent markers"),
        Agent(id: "d9", type: "general-purpose", task: "Map the feed adapter")
    ]
    static let turnSteps = [
        Step(id: 1, tool: "Read", summary: "internal/sessionfeed/live.go", time: "0:01"),
        Step(id: 2, tool: "Grep", summary: "\"LiveAction\" in internal/", time: "0:01"),
        Step(id: 3, tool: "Read", summary: "internal/sessionfeed/live_test.go", time: "0:02"),
        Step(id: 4, tool: "Edit", summary: "internal/sessionfeed/live.go", time: "0:03"),
        Step(id: 5, tool: "Bash", summary: "go test ./internal/sessionfeed", time: "0:14"),
        Step(id: 6, tool: "Edit", summary: "internal/sessionfeed/live.go — cap the steps at 40", time: "0:02"),
        Step(id: 7, tool: "Agent", summary: "codex-wrapper — Codex review of the plan", time: "0:41"),
        Step(id: 8, tool: "Bash", summary: "go test ./internal/sessionfeed -run TestLiveSteps", time: "0:07", running: true)
    ]

    // MARK: - States (spec §Mockups)

    static let workingDoneCollapsed = Self(badge: .working(2), list: .agents(doneOpen: false),
                                           working: workingAgents, done: doneAgents, steps: turnSteps)
    static let doneExpanded = Self(badge: .working(2), list: .agents(doneOpen: true),
                                   working: workingAgents, done: doneAgents, steps: turnSteps)
    static let onlyDone = Self(badge: .done(9), list: .agents(doneOpen: true), done: doneAgents, steps: turnSteps)
    static let noAgents = Self(badge: .none, list: .closed, steps: turnSteps)
    static let unknown = Self(badge: .unknown, list: .agents(doneOpen: true), done: doneAgents, steps: turnSteps)
    static let listLoading = Self(badge: .working(2), list: .loading, steps: turnSteps)
    static let listError = Self(badge: .working(2), list: .error, steps: turnSteps)
    static let stepsOpenWide = Self(badge: .working(2), list: .closed, steps: turnSteps, stepsOpen: true)
    static let stepsOpenNarrow = Self(badge: .working(2), list: .closed, steps: turnSteps, stepsOpen: true, narrow: true)
    static let feedOnly = Self(badge: .working(2), list: .closed, steps: turnSteps)
    static let idleDone = Self(badge: .done(9), list: .closed, done: doneAgents, idle: true)
    static let typingWhileWorking = Self(badge: .working(2), list: .closed, steps: turnSteps,
                                         draft: [.text("and skip the phone filter for now")],
                                         queuedLine: "Run the lock metrics check after the tests.")
    static let pasteTokens = Self(badge: .working(2), list: .closed, steps: turnSteps,
                                  draft: [.text("fix this"), .image("Image #1"), .text("and look at"),
                                          .paste("Pasted text #2 +42 lines")])
    static let endedDone = Self(badge: .done(9), list: .closed, done: doneAgents, idle: true, ended: true)
}

@MainActor
enum WorkchatAgentsMockShotFixtures {
    static let shots: [DesignShot] = [
        shot("01-working-done-collapsed", .workingDoneCollapsed),
        shot("02-done-expanded", .doneExpanded, height: 600),
        shot("03-only-done", .onlyDone, height: 560),
        shot("04-none", .noAgents),
        shot("05-unknown", .unknown, height: 560),
        shot("06-loading", .listLoading),
        shot("07-error", .listError),
        shot("08-steps-open", .stepsOpenWide),
        shot("09-steps-narrow", .stepsOpenNarrow, width: 340),
        shot("10-feed-no-cards", .feedOnly),
        shot("11-idle", .idleDone),
        shot("12-ended", .endedDone),
        shot("13-send-while-working", .typingWhileWorking),
        shot("14-paste-tokens", .pasteTokens)
    ]

    private static func shot(_ name: String, _ mock: WorkchatAgentsMock, width: CGFloat = 720, height: CGFloat = 480) -> DesignShot {
        DesignShot(name: "workchat-agents-\(name)", size: NSSize(width: width, height: height)) {
            AnyView(WorkchatAgentsMockShot(mock: mock))
        }
    }
}

/// The Workchat pane as the spec draws it: feed, optional steps list, live
/// line, composer; the 👥 list floats over the feed where its popover opens.
@MainActor
struct WorkchatAgentsMockShot: View {
    let mock: WorkchatAgentsMock

    var body: some View {
        VStack(spacing: 0) {
            feed
            if mock.stepsOpen { WorkchatStepsMock(steps: mock.steps).padding(.horizontal, Spacing.large) }
            if mock.ended {
                // As SessionChatView draws it today: a pane hairline, then the line.
                Divider()
                Text(WorkchatAgentsMock.endedLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Today's ended line pads `cozy`; the mock aligns it with the caption row below.
                    .padding(.horizontal, Spacing.large)
                    .padding(.top, Spacing.cozy)
                liveLine.padding(.bottom, Spacing.small)
            } else {
                liveLine
                composer
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .detailBackground()
        .overlay(alignment: .bottomTrailing) {
            if listOpen {
                WorkchatAgentsListMock(mock: mock)
                    .padding(.trailing, Spacing.large)
                    .padding(.bottom, Spacing.hero * 2 + Spacing.small)
            }
        }
    }

    private var feed: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.large) {
                ForEach(Array(WorkchatAgentsMock.feed.enumerated()), id: \.offset) { index, message in
                    if message.owner {
                        Text(message.text)
                            .padding(.horizontal, Spacing.cozy)
                            .padding(.vertical, Spacing.compact)
                            .background(Tone.status("blue").opacity(ChipTint.fillOpacity),
                                        in: RoundedRectangle(cornerRadius: Radius.bubble))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.leading, Spacing.hero)
                    } else {
                        let last = index == WorkchatAgentsMock.feed.count - 1
                        Text(mock.idle && last ? WorkchatAgentsMock.idleReply : message.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let queued = mock.queuedLine {
                    VStack(alignment: .trailing, spacing: Spacing.small) {
                        Text(queued)
                            .padding(.horizontal, Spacing.cozy)
                            .padding(.vertical, Spacing.compact)
                            .background(Tone.status("blue").opacity(ChipTint.fillOpacity),
                                        in: RoundedRectangle(cornerRadius: Radius.bubble))
                        Text(WorkchatAgentsMock.queuedCaption).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.leading, Spacing.hero)
                }
            }
            .padding(Spacing.large)
        }
        .defaultScrollAnchor(.bottom)
        .frame(maxHeight: .infinity)
    }

    private var liveLine: some View {
        HStack(spacing: Spacing.compact) {
            if !mock.idle {
                Image(systemName: mock.stepsOpen ? "chevron.down" : "chevron.up")
                    .font(.system(size: IconSize.chevron, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: IconSize.header)
                Image(systemName: WorkchatActivityPresenter.symbol(for: "Bash")).frame(width: IconSize.header)
                Text(WorkchatAgentsMock.lineText).lineLimit(1).truncationMode(.middle)
                if !mock.narrow { Text(WorkchatAgentsMock.lineMore).foregroundStyle(.tertiary).fixedSize() }
            }
            Spacer(minLength: Spacing.compact)
            agentsButton
            if !mock.idle { Text(WorkchatAgentsMock.lineElapsed).monospacedDigit() }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: ListLayout.lineMinHeight)
    }

    @ViewBuilder private var agentsButton: some View {
        switch mock.badge {
        case .none:
            EmptyView()
        case .working(let count):
            badgeButton(symbol: "person.2", text: "\(count)", isOn: listOpen)
        case .done(let count):
            badgeButton(symbol: "checkmark", text: "\(count)", isOn: listOpen, dimmed: true)
        case .unknown:
            badgeButton(symbol: "person.2", text: "?", isOn: listOpen)
        }
    }

    private var listOpen: Bool {
        if case .closed = mock.list { return false }
        return true
    }

    /// A dimmed badge (only finished agents) is tertiary on a resting fill,
    /// so it still reads as a button in Light.
    private func badgeButton(symbol: String, text: String, isOn: Bool, dimmed: Bool = false) -> some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: symbol)
            Text(text).monospacedDigit()
        }
        .foregroundStyle(dimmed ? .tertiary : .secondary)
        .padding(.horizontal, Spacing.compact)
        .padding(.vertical, Spacing.tight)
        .background(isOn ? Fill.hover : (dimmed ? Fill.rest : .clear), in: Capsule())
    }

    @ViewBuilder private func draftPart(_ part: WorkchatAgentsMock.Part) -> some View {
        switch part {
        case .text(let text):
            Text(text)
        case .image(let label):
            token(label, symbol: "photo")
        case .paste(let label):
            token(label, symbol: "doc.plaintext")
        }
    }

    /// An atomic paste token inside the field (spec §6): one Backspace removes it.
    private func token(_ label: String, symbol: String) -> some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: symbol)
            Text(label)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Spacing.compact)
        .padding(.vertical, Spacing.tight)
        .background(Fill.selected, in: RoundedRectangle(cornerRadius: Radius.mark))
        .fixedSize()
    }

    private var composer: some View {
        HStack(spacing: Spacing.compact) {
            Image(systemName: "paperclip").foregroundStyle(.secondary)
            if let draft = mock.draft {
                HStack(spacing: Spacing.small) {
                    ForEach(draft, id: \.self) { part in draftPart(part) }
                }
                .lineLimit(1)
            } else {
                Text(WorkchatAgentsMock.placeholder).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: Spacing.compact)
            // Send whenever the field holds something (spec §5); Stop only with an empty field mid-turn.
            Image(systemName: mock.idle || mock.draft != nil ? "arrow.up" : "stop.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Tone.status("blue"))
                .frame(width: IconSize.composerLarge, height: IconSize.composerLarge)
        }
        .padding(Spacing.cozy)
        .background(Surface.text, in: RoundedRectangle(cornerRadius: Radius.control))
        .padding(.horizontal, Spacing.large)
        .padding(.bottom, Spacing.large)
    }
}

/// The current turn's steps: up to six rows visible, newest at the bottom,
/// scrolled to the end (drawn statically as the last six rows with a fade
/// over the cut-off top, which is what the pinned scroll view shows).
struct WorkchatStepsMock: View {
    let steps: [WorkchatAgentsMock.Step]
    private static let visibleRows = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(steps) { step in
                HStack(spacing: Spacing.compact) {
                    Image(systemName: WorkchatActivityPresenter.symbol(for: step.tool))
                        .foregroundStyle(step.running ? .primary : .secondary)
                        .frame(width: IconSize.header)
                    Text(step.summary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(step.running ? .primary : .secondary)
                    Spacer(minLength: Spacing.compact)
                    Text(step.time)
                        .monospacedDigit()
                        .foregroundStyle(step.running ? .secondary : .tertiary)
                }
                .frame(height: ListLayout.lineMinHeight)
            }
        }
        .font(.caption)
        .padding(.horizontal, Spacing.regular)
        // Six rows and half of the seventh, so the cut-off top reads as "scrolls".
        .frame(height: (CGFloat(Self.visibleRows) + 0.5) * ListLayout.lineMinHeight, alignment: .bottom)
        .padding(.bottom, Spacing.small)
        .clipped()
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.2)],
                             startPoint: .top, endPoint: .bottom))
        .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.row))
        .padding(.bottom, Spacing.small)
    }
}

/// The 👥 list's popover body: Working rows, then the collapsible Done part.
struct WorkchatAgentsListMock: View {
    let mock: WorkchatAgentsMock
    private static let doneVisibleRows: CGFloat = 5
    private static let twoLineRow: CGFloat = ListLayout.rowMinHeight + Spacing.large

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text(WorkchatAgentsMock.listTitle).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            switch mock.list {
            case .closed:
                EmptyView()
            case .loading:
                HStack(spacing: Spacing.regular) {
                    ProgressView().controlSize(.small)
                    Text(WorkchatAgentsMock.loading).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, Spacing.regular)
            case .error:
                HStack(spacing: Spacing.regular) {
                    Image(systemName: "exclamationmark.circle")
                    Text(WorkchatAgentsMock.error)
                    Spacer(minLength: Spacing.regular)
                    Button(WorkchatAgentsMock.retry) {}.buttonStyle(.kitSecondary).controlSize(.small)
                }
                .font(.caption)
                .foregroundStyle(Tone.warning)
                .padding(.vertical, Spacing.small)
            case .agents(let doneOpen):
                agents(doneOpen: doneOpen)
            }
        }
        .padding(Spacing.medium)
        .frame(width: PaneWidth.sideListMax, alignment: .leading)
        .popoverSurface()
        .background(Surface.window, in: RoundedRectangle(cornerRadius: Radius.container))
        .overlay(RoundedRectangle(cornerRadius: Radius.container).strokeBorder(.quaternary, lineWidth: Stroke.hairline))
    }

    @ViewBuilder private func agents(doneOpen: Bool) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            caps(WorkchatAgentsMock.workingTitle)
            if case .unknown = mock.badge {
                note(WorkchatAgentsMock.unknownWorking, symbol: "questionmark.circle")
            } else if mock.working.isEmpty {
                note(WorkchatAgentsMock.noneWorking, symbol: nil)
            }
            ForEach(mock.working) { agent in
                row(agent, symbol: WorkchatActivityPresenter.symbol(for: agent.tool), tint: nil,
                    subtitle: "\(agent.task) · \(agent.action)", trailing: agent.elapsed)
            }
        }
        if !mock.done.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(spacing: Spacing.compact) {
                    Image(systemName: doneOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: IconSize.chevron, weight: .semibold))
                        .frame(width: IconSize.header)
                    Text(WorkchatAgentsMock.doneTitle(mock.done.count))
                    Spacer(minLength: 0)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .kitRow(isSelected: false)
                if doneOpen {
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        ForEach(mock.done) { agent in
                            row(agent, symbol: "checkmark.circle", tint: Tone.success, subtitle: agent.task, trailing: nil)
                        }
                    }
                    .frame(height: Self.doneVisibleRows * Self.twoLineRow + Spacing.small * 4, alignment: .top)
                    .clipped()
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                }
            }
        }
    }

    private func caps(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .tracking(Tracking.caps)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, Spacing.regular)
            .padding(.top, Spacing.small)
    }

    private func note(_ text: String, symbol: String?) -> some View {
        HStack(spacing: Spacing.compact) {
            if let symbol { Image(systemName: symbol).frame(width: IconSize.header) }
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Spacing.regular)
        .padding(.vertical, Spacing.small)
    }

    private func row(_ agent: WorkchatAgentsMock.Agent, symbol: String, tint: Color?, subtitle: String, trailing: String?) -> some View {
        HStack(alignment: .center, spacing: Spacing.regular) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tint ?? .secondary)
                .frame(width: IconSize.header)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(agent.type).font(.callout).foregroundStyle(.primary).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: Spacing.small)
            if let trailing { Text(trailing).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .kitRow(isSelected: false)
    }
}

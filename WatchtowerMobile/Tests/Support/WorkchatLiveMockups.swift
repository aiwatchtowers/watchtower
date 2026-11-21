import SwiftUI
@testable import WatchtowerMobile

/// Static mockups for spec 2026-11-20 "Phone Workchat: the live line" (#2112): the session chat with the Mac's live
/// line above the composer, the turn's steps behind a tap, the agents sheet with live Working rows, and the line's
/// loading, error, stale, hidden and empty states. Built from the phone's design pieces (`ChatBubble`, `StateLine`,
/// `FlatRow`, `SectionHeader`, `InlinePermissionCard`, `WorkchatComposerBar`); nothing is wired to a model.
/// `make mobile-shots SHOTS_ONLY=workchat-live` draws them (`testTheWorkchatLiveShots`).
@MainActor
enum WorkchatLiveMockups {
    /// One line of the mock: what the shared `WorkchatLivePresentation.Row` would hold.
    struct Line {
        var symbol: String
        var text: String
        var elapsed: String?
        var pulse = false
        var warning = false
        var retry = false
        var steps: StepsChevron = .none
    }

    /// The steps disclosure on the line: none without a slot, else open or closed.
    enum StepsChevron {
        case none, open, closed
    }

    struct Step: Identifiable {
        let symbol: String
        let summary: String
        let time: String
        var running = false
        var id: String { summary }
    }

    struct LiveAgent: Identifiable {
        let type: String
        let description: String
        let action: String
        let elapsed: String
        var id: String { type + description }
    }

    // MARK: - Frames

    static let frames: [(String, AnyView)] = [
        ("workchat-live-L1", AnyView(l1)), ("workchat-live-L2", AnyView(l2)), ("workchat-live-L3", AnyView(l3)),
        ("workchat-live-L4", AnyView(l4)), ("workchat-live-L5", AnyView(l5)), ("workchat-live-L6", AnyView(l6)),
        ("workchat-live-L7", AnyView(l7)), ("workchat-live-L8", AnyView(l8)), ("workchat-live-L9", AnyView(l9)),
        ("workchat-live-L10", AnyView(l10))
    ]

    /// L1: a step runs: its symbol pulses, the summary, the step's timer; the steps chevron; toolbar agents 2.
    static var l1: some View {
        screen(line: Line(symbol: "terminal", text: "Running tests · go test ./internal/sessionfeed", elapsed: "0:12",
                          pulse: true, steps: .closed), agents: 2)
    }

    /// L2: the steps slot open above the line (6 rows tall, scrolls), the line sums up the turn.
    static var l2: some View {
        screen(line: Line(symbol: "list.bullet", text: "This turn · 9 steps", elapsed: "1:47", steps: .open),
               steps: steps, agents: 2)
    }

    /// L3: between tools: "Working…" with the turn's timer.
    static var l3: some View {
        screen(line: Line(symbol: "ellipsis", text: "Working…", elapsed: "0:31", steps: .closed), agents: nil)
    }

    /// L4: the chat just opened, the live block has not arrived: "Loading activity…" with the state timer.
    static var l4: some View {
        screen(line: Line(symbol: "ellipsis", text: "Loading activity…", elapsed: "3:14"), agents: nil)
    }

    /// L5: the hub could not read the live block: "Activity unavailable" and Retry; the dialog still updates.
    static var l5: some View {
        screen(line: Line(symbol: "exclamationmark.circle", text: "Activity unavailable", warning: true, retry: true),
               agents: nil)
    }

    /// L6: the tower stopped sending: the freshness line under the header, the live line out of date, no timer.
    static var l6: some View {
        screen(line: Line(symbol: "clock", text: "Activity out of date · 42s ago", warning: true, retry: true),
               agents: nil, freshness: "Updated 15:20 · Acme Mac is not sending updates")
    }

    /// L7: a permission card above the composer: the line steps aside (the card says what waits).
    static var l7: some View {
        screen(line: nil, agents: 2, permission: true)
    }

    /// L8: a subagent's own chat (narrow scope): the line shows that agent's step.
    static var l8: some View {
        screen(line: Line(symbol: "magnifyingglass", text: "Grep · \"func LiveOf\" in internal/", elapsed: "0:04",
                          pulse: true, steps: .closed),
               agents: nil, title: "Explore · Recon the DB layer", entries: subagentFeed)
    }

    /// L9: the agents sheet: Working rows say what each agent does now and for how long; Done collapsed.
    static var l9: some View {
        screen(line: Line(symbol: "person.2", text: "Agent · Codex review of the lane split", elapsed: "2:05",
                          pulse: true, steps: .closed),
               agents: 2, sheet: true)
    }

    /// L10: no turn runs: no line, the composer sits on the feed.
    static var l10: some View {
        screen(line: nil, agents: nil, state: yourTurnState, entries: workingFeed + finishedFeed)
    }

    // MARK: - Content

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static let steps: [Step] = [
        Step(symbol: "doc.text", summary: "Read · internal/sessionfeed/live.go", time: "0:01"),
        Step(symbol: "magnifyingglass", summary: "Grep · \"OnChange\" in internal/hub", time: "0:01"),
        Step(symbol: "person.2", summary: "Agent · Recon the DB layer", time: "0:48"),
        Step(symbol: "pencil", summary: "Edit · session_chat.go", time: "0:02"),
        Step(symbol: "pencil", summary: "Edit · session_chat_test.go", time: "0:02"),
        Step(symbol: "terminal", summary: "Running tests · go test ./internal/hub/...", time: "0:12", running: true)
    ]

    static let liveWorking = [
        LiveAgent(type: "Explore", description: "Recon the DB layer", action: "Grep · \"func LiveOf\" in internal/",
                  elapsed: "0:04"),
        LiveAgent(type: "codex-wrapper", description: "Codex review of the lane split",
                  action: "Bash · codex review --base main", elapsed: "2:05")
    ]

    private static var workingState: StateLineModel {
        StateLineModel(glyph: nil, tone: .green, caption: "Working", isWaiting: false, stateAt: now.addingTimeInterval(-194), now: now)
    }

    private static var yourTurnState: StateLineModel {
        StateLineModel(
            glyph: "arrowshape.turn.up.left.fill", tone: .orange, caption: "Your turn", isWaiting: true,
            stateAt: now.addingTimeInterval(-60), now: now
        )
    }

    private static let workingFeed: [(ChatBubble.Role, String)] = [
        (.watchtower, "Brief · Live line on the phone"),
        (.owner, "Show on the phone what the agent is doing, like the Mac's Workchat."),
        (.agent, "I'll add the live block to the session chat payload and read the transcript on change instead of every 3 s.")
    ]

    private static let finishedFeed: [(ChatBubble.Role, String)] = [
        (.agent, "Done: the hub reads on change and the phone shows the line. **Tests green.**")
    ]

    private static let subagentFeed: [(ChatBubble.Role, String)] = [
        (.watchtower, "Task · Recon the DB layer"),
        (.agent, "Looking for where the live snapshot is read and who calls it.")
    ]

    private static func screen(
        line: Line?,
        steps: [Step]? = nil,
        agents: Int?,
        state: StateLineModel? = nil,
        title: String = "Live line",
        entries: [(ChatBubble.Role, String)]? = nil,
        freshness: String? = nil,
        permission: Bool = false,
        sheet: Bool = false
    ) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    Text("acme").font(TypeScale.meta).foregroundStyle(.secondary)
                    Text(title).font(TypeScale.pageTitle)
                    StateLine(model: state ?? workingState)
                    if let freshness {
                        Label { Text(freshness) } icon: { Image(systemName: "exclamationmark.arrow.circlepath") }
                            .font(TypeScale.meta)
                            .foregroundStyle(PhoneTone.red.color)
                            .padding(.vertical, Spacing.small)
                    }
                }
                .padding(.horizontal, Spacing.large)
                .padding(.bottom, Spacing.regular)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.medium) {
                        ForEach(Array((entries ?? workingFeed).enumerated()), id: \.offset) { _, entry in
                            ChatBubble(role: entry.0, text: entry.1)
                        }
                    }
                    .padding(.horizontal, Spacing.large)
                    .padding(.vertical, Spacing.regular)
                }
                .defaultScrollAnchor(.bottom)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(.systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    if permission {
                        InlinePermissionCard(toolName: "Bash", summary: "rm -rf build/mobile-shots", onAllow: {}, onDeny: {})
                            .padding(.horizontal, Spacing.large)
                            .padding(.vertical, Spacing.regular)
                    }
                    if let steps { StepsSlot(steps: steps) }
                    if let line { LiveLine(line: line) }
                    WorkchatComposerBar(text: .constant(""), mode: permission ? .answerAbove : .message) {}
                }
                .background(Color(.systemBackground))
            }
            .toolbar {
                if let agents {
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: Spacing.small) {
                            Image(systemName: "person.2")
                            CountBadge(count: agents, tone: .accent)
                        }
                        .foregroundStyle(Color.accentColor)
                        .frame(minHeight: PhoneMetrics.minTouch)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Image(systemName: "ellipsis.circle").frame(minWidth: PhoneMetrics.minTouch, minHeight: PhoneMetrics.minTouch)
                }
            }
            .sheet(isPresented: .constant(sheet)) {
                LiveAgentsSheet(working: liveWorking, doneCount: 9)
            }
        }
    }
}

/// The live line: symbol, text cut in the middle, then Retry or the timer and the steps chevron. The whole line is
/// the steps toggle when it has a slot.
private struct LiveLine: View {
    let line: WorkchatLiveMockups.Line

    var body: some View {
        HStack(spacing: Spacing.compact) {
            Image(systemName: line.symbol)
                .symbolEffect(.pulse, isActive: line.pulse)
                .frame(width: PhoneMetrics.iconColumn)
            Text(line.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Spacing.compact)
            if line.retry {
                Text("Retry").font(TypeScale.meta.weight(.semibold)).foregroundStyle(Color.accentColor)
            }
            if let elapsed = line.elapsed {
                Text(elapsed).monospacedDigit()
            }
            if line.steps != .none {
                Image(systemName: line.steps == .open ? "chevron.down" : "chevron.up").font(TypeScale.capsHeader)
            }
        }
        .font(TypeScale.meta)
        .foregroundStyle(line.warning ? PhoneTone.orange.color : Color.secondary)
        .padding(.horizontal, Spacing.large)
        .padding(.vertical, Spacing.regular)
        .frame(minHeight: PhoneMetrics.minTouch)
        .background(Fill.rest)
    }
}

/// The turn's steps above the line: a fixed six-row slot that scrolls past that, the running step last.
private struct StepsSlot: View {
    let steps: [WorkchatLiveMockups.Step]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(steps) { step in
                HStack(spacing: Spacing.compact) {
                    Image(systemName: step.symbol)
                        .symbolEffect(.pulse, isActive: step.running)
                        .frame(width: PhoneMetrics.iconColumn)
                    Text(step.summary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: Spacing.compact)
                    Text(step.time).monospacedDigit()
                }
                .font(TypeScale.meta)
                .foregroundStyle(step.running ? Color.primary : Color.secondary)
                .padding(.horizontal, Spacing.large)
                .padding(.vertical, Spacing.small)
            }
        }
        .padding(.vertical, Spacing.small)
        .background(Fill.rest)
    }
}

/// The agents sheet with live data: a Working row is type, description, and under it the agent's step and timer.
private struct LiveAgentsSheet: View {
    let working: [WorkchatLiveMockups.LiveAgent]
    let doneCount: Int

    private static let rowInsets = EdgeInsets(top: Spacing.regular, leading: Spacing.small, bottom: Spacing.regular, trailing: Spacing.small)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader("Working", count: working.count)
                    ForEach(working) { agent in
                        FlatRow(icon: .session(tone: .green, isRing: false), title: agent.type, titleLineLimit: 1, insets: Self.rowInsets) {
                            VStack(alignment: .leading, spacing: Spacing.small) {
                                Text(agent.description)
                                Label { Text(agent.action).lineLimit(1).truncationMode(.middle) } icon: {
                                    Image(systemName: "terminal")
                                }
                                .font(TypeScale.meta)
                                .foregroundStyle(.secondary)
                            }
                        } trailing: {
                            HStack(spacing: Spacing.regular) {
                                Text(agent.elapsed).font(TypeScale.meta).monospacedDigit().foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(TypeScale.meta).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    HStack(spacing: Spacing.compact) {
                        Image(systemName: "chevron.right").font(TypeScale.capsHeader).frame(width: PhoneMetrics.iconColumn)
                        Text("Done · \(doneCount)").font(TypeScale.sectionHeader)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .padding(Self.rowInsets)
                    .frame(minHeight: PhoneMetrics.minTouch)
                    .padding(.top, Spacing.small)
                }
                .padding(.horizontal, Spacing.large)
            }
            .navigationTitle("Agents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Image(systemName: "xmark") }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color(.systemBackground))
    }
}

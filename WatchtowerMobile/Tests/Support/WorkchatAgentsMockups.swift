import SwiftUI
@testable import WatchtowerMobile

/// Static mockups for spec 2026-11-19 "Workchat agents and progress" (#2065), §1–§2 on the phone: the session chat
/// without subagent cards, an agents button in its toolbar, and the agents sheet (Working, Done · N). Built from the
/// phone's design pieces (`ChatBubble`, `StateLine`, `FlatRow`, `SectionHeader`, `WorkchatComposerBar`); nothing here
/// is wired to a model. `make mobile-shots SHOTS_ONLY=workchat-agents` draws them (`testTheWorkchatAgentsShots`).
@MainActor
enum WorkchatAgentsMockups {
    struct Agent: Identifiable {
        let type: String
        let description: String
        var id: String { type + description }
    }

    /// The toolbar button's face: the working count, or a dimmed `✓ N` once every agent is done.
    enum Badge {
        case working(Int)
        case done(Int)
    }

    static let working = [
        Agent(type: "Explore", description: "Recon the DB layer"),
        Agent(type: "codex-wrapper", description: "Codex review of the lane split")
    ]

    static let done = [
        Agent(type: "Explore", description: "Find where lanes are ordered"),
        Agent(type: "general-purpose", description: "Draft the lane fixture"),
        Agent(type: "Plan", description: "Plan the test split"),
        Agent(type: "Explore", description: "Map BoardModel callers"),
        Agent(type: "style-guardian", description: "Style pass on the fixture"),
        Agent(type: "codex-wrapper", description: "Codex review, round 1"),
        Agent(type: "general-purpose", description: "Fix the flaky lane order"),
        Agent(type: "Explore", description: "Check the Kit fixture keys"),
        Agent(type: "review-prosecutor", description: "Review the split")
    ]

    // MARK: - Frames

    /// P1: the chat while the agent works, two agents running: no agent cards in the feed, the button says 2.
    static var p1: some View {
        screen(badge: .working(working.count), state: workingState, entries: workingFeed)
    }

    /// P2: the sheet over the same chat: Working (2) and Done · 9 collapsed.
    static var p2: some View {
        screen(badge: .working(working.count), state: workingState, entries: workingFeed, sheet: AgentsSheet(working: working, done: done))
    }

    /// P3: the turn is over, every agent finished: the button is a dimmed `✓ 9`, the sheet opens Done by itself.
    static var p3: some View {
        screen(badge: .done(done.count), state: yourTurnState, entries: workingFeed + finishedFeed, sheet: AgentsSheet(working: [], done: done))
    }

    /// P4: a session that started no agents: no button at all.
    static var p4: some View {
        screen(badge: nil, state: workingState, entries: plainFeed)
    }

    // MARK: - Content

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

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
        (.watchtower, "Brief · Split the board lanes test"),
        (.owner, "Split the board lanes test into one test per lane and make each pass."),
        (.agent, "I'll map how the lanes are built first. Two agents are looking at the DB layer and the existing review notes."),
        (.agent, "Lane order comes from `BoardModel.lanes`; the test builds its own copy, which is why it drifts.")
    ]

    private static let finishedFeed: [(ChatBubble.Role, String)] = [
        (.agent, "Done: four lane tests, each with its own fixture. The Codex review found nothing left to fix. **All green.**")
    ]

    private static let plainFeed: [(ChatBubble.Role, String)] = [
        (.watchtower, "Brief · Rename the archive menu item"),
        (.owner, "Rename \"Archive\" to \"Archive closed\" in the board menu."),
        (.agent, "Renamed it in `BoardMenu.swift` and in the guide page. Running the board tests now.")
    ]

    private static func screen(
        badge: Badge?, state: StateLineModel, entries: [(ChatBubble.Role, String)], sheet: AgentsSheet? = nil
    ) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    Text("acme").font(TypeScale.meta).foregroundStyle(.secondary)
                    Text("Board lanes").font(TypeScale.pageTitle)
                    StateLine(model: state)
                }
                .padding(.horizontal, Spacing.large)
                .padding(.bottom, Spacing.regular)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.medium) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
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
                WorkchatComposerBar(text: .constant(""), mode: .message) {}
            }
            .toolbar {
                if let badge {
                    ToolbarItem(placement: .topBarTrailing) { AgentsButton(badge: badge) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Image(systemName: "ellipsis.circle").frame(minWidth: PhoneMetrics.minTouch, minHeight: PhoneMetrics.minTouch)
                }
            }
            .sheet(isPresented: .constant(sheet != nil)) {
                if let sheet { sheet }
            }
        }
    }
}

/// The toolbar's agents button: two people and the working count on an accent badge, or, with none working, a dimmed
/// `✓ N` on a faint capsule so it still reads as a button.
private struct AgentsButton: View {
    let badge: WorkchatAgentsMockups.Badge

    var body: some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: "person.2")
            switch badge {
            case let .working(count):
                CountBadge(count: count, tone: .accent)
            case let .done(count):
                Text("✓ \(count)").font(TypeScale.badge).monospacedDigit()
            }
        }
        .foregroundStyle(isDone ? Color.secondary : Color.accentColor)
        .padding(.horizontal, isDone ? Spacing.regular : 0)
        .padding(.vertical, isDone ? Spacing.small : 0)
        .background(isDone ? Fill.rest : .clear, in: Capsule())
        .frame(minHeight: PhoneMetrics.minTouch)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agents")
    }

    private var isDone: Bool {
        if case .done = badge { return true }
        return false
    }
}

/// The agents sheet: Working (type, description, "Running"; no timer, the phone has no live snapshot) and a
/// collapsible Done · N, open by itself when nothing works.
private struct AgentsSheet: View {
    let working: [WorkchatAgentsMockups.Agent]
    let done: [WorkchatAgentsMockups.Agent]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !working.isEmpty {
                        SectionHeader("Working", count: working.count)
                        ForEach(working) { agent in
                            row(agent, icon: .session(tone: .green, isRing: false)) {
                                Text("Running").font(TypeScale.meta).foregroundStyle(.secondary)
                            }
                        }
                    }
                    doneHeader
                    if working.isEmpty {
                        ForEach(done) { agent in
                            row(agent, icon: .symbol("checkmark.circle", tone: .secondary)) { EmptyView() }
                        }
                    }
                }
                .padding(.horizontal, Spacing.large)
            }
            .navigationTitle("Agents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") {} }
            }
        }
        .presentationDetents([.medium, .large])
        // Opaque: the screenshot host's drawHierarchy draws no blur, so the glass sheet would show the chat through it.
        .presentationBackground(Color(.systemBackground))
    }

    /// The rows line up with the section header's text (its `Spacing.small` inset), not with the page.
    private static let rowInsets = EdgeInsets(top: Spacing.regular, leading: Spacing.small, bottom: Spacing.regular, trailing: Spacing.small)

    private var doneHeader: some View {
        HStack(spacing: Spacing.compact) {
            Image(systemName: working.isEmpty ? "chevron.down" : "chevron.right")
                .font(TypeScale.capsHeader)
                .frame(width: PhoneMetrics.iconColumn)
            Text("Done · \(done.count)").font(TypeScale.sectionHeader)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(Self.rowInsets)
        .frame(minHeight: PhoneMetrics.minTouch)
        .padding(.top, working.isEmpty ? Spacing.regular : Spacing.small)
    }

    private func row(
        _ agent: WorkchatAgentsMockups.Agent, icon: FlatRowIcon, @ViewBuilder status: () -> some View
    ) -> some View {
        FlatRow(icon: icon, title: agent.type, titleLineLimit: 1, insets: Self.rowInsets) {
            Text(agent.description)
        } trailing: {
            HStack(spacing: Spacing.regular) {
                status()
                Image(systemName: "chevron.right").font(TypeScale.meta).foregroundStyle(.tertiary)
            }
        }
    }
}

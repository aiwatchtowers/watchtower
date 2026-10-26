import SwiftUI
import WatchtowerKit
@testable import WatchtowerMobile

/// The design system's parts in the mockups' states
/// (`docs/design/mobile/mockups.html`), one page per mockup group, for the
/// screenshot tour's `designSystemShots()`. Demo data only.
enum DesignSystemGallery {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A page: a navigation title over a padded scroll view.
    struct Page<Content: View>: View {
        let title: String
        @ViewBuilder let content: Content

        var body: some View {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.regular) { content }
                        .padding(.horizontal, Spacing.large)
                        .padding(.bottom, Spacing.wide)
                }
                .background(Color(.systemBackground))
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    /// Mockup 1: the Mac chip, caps headers, waiting and working cards, the
    /// next meeting.
    static var nowPage: some View {
        Page(title: "Now") {
            HStack {
                MacStatusChip(model: MacStatusChipModel(macName: "MacBook Pro", state: .online, now: now))
                MacStatusChip(model: MacStatusChipModel(macName: "MacBook Pro", state: .asleep(lastSeen: now - 720), now: now))
            }
            SectionHeader("Waiting for you", count: 3).padding(.horizontal, -Spacing.large)
            VStack(spacing: 0) {
                FlatRow(icon: .state(glyph: "questionmark", tone: .waitingForYou), title: "Which export format do we keep for finance?",
                        insets: EdgeInsets()) {
                    Text("acme · Billing export · ask #109")
                } trailing: {
                    Text("4m").font(TypeScale.time).foregroundStyle(.tertiary)
                }
            }
            .card()
            VStack(spacing: 0) {
                FlatRow(icon: .state(glyph: "hand.raised.fill", tone: .waitingForYou), title: "Needs approval: Bash", insets: EdgeInsets()) {
                    Text("go test ./internal/billing/...").font(TypeScale.code)
                } trailing: {
                    Text("1m").font(TypeScale.time).foregroundStyle(.tertiary)
                }
            }
            .card()
            VStack(spacing: 0) {
                FlatRow(icon: .state(glyph: "checkmark", tone: .blue), title: "Invoice PDF layout — finished", insets: EdgeInsets()) {
                    Text("acme-web · “Layout fixed, PR #212 opened.”")
                }
            }
            .card()
            SectionHeader("Working", count: 2).padding(.horizontal, -Spacing.large)
            VStack(spacing: 0) {
                FlatRow(icon: .session(tone: .green, isRing: false), title: "Session report", insets: EdgeInsets()) {
                    Text("acme")
                } trailing: {
                    Text("3:14").font(TypeScale.time).foregroundStyle(.tertiary)
                }
                CardRowDivider()
                FlatRow(icon: .session(tone: .green, isRing: false), title: "Archive closed targets", isSelected: true, insets: EdgeInsets()) {
                    Text("acme · Agents working · 2")
                } trailing: {
                    Text("12:40").font(TypeScale.time).foregroundStyle(.tertiary)
                }
            }
            .card(padding: EdgeInsets(top: Spacing.small, leading: Spacing.medium, bottom: Spacing.small, trailing: Spacing.medium))
            SectionHeader("Next meeting").padding(.horizontal, -Spacing.large)
            CalendarRow(model: CalendarRowModel(
                start: now + 1_500, end: now + 3_300, title: "Design critique", location: "meet.example.com",
                attendees: 4, isNext: true, now: now
            ))
        }
    }

    private static func chatHeader(_ title: String, _ state: StateLineModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(title).font(.headline)
            StateLine(model: state)
        }
        .padding(.bottom, Spacing.regular)
    }

    /// Mockup 3: working, the dialog, a queued line, the composer.
    static var workchatWorkingPage: some View {
        Page(title: "acme") {
            chatHeader("Session report", StateLineModel(
                glyph: nil, tone: .green, caption: "Working", isWaiting: false, stateAt: now - 194, now: now
            ))
            VStack(spacing: Spacing.medium) {
                ChatBubble(role: .watchtower, text: "Brief · target #343 Session report")
                ChatBubble(role: .owner, text: "Add the PR link to the report header, then run the report tests.")
                ChatBubble(role: .agent, text: "Added `pr_url` to the header model and the renderer. Running `go test ./internal/sessionreport` now.")
                ChatBubble(role: .subagent, text: "Explore · “find every caller of renderHeader” · finished") {}
                ChatBubble(role: .agent, text: "All 42 tests pass. Next I'll update the Desktop card so the link opens in the browser.")
                ChatBubble(role: .owner, text: "And keep the old header for sessions without a PR.",
                           caption: "Queued · the agent reads it at its next step", isPending: true)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            WorkchatComposerBar(text: .constant(""), mode: .message) {}
        }
    }

    /// Mockup 4: waiting, a permission card and an ask inline.
    static var workchatWaitingPage: some View {
        Page(title: "acme") {
            chatHeader("Login redirect", StateLineModel(
                glyph: "hand.raised.fill", tone: .waitingForYou, caption: "Needs approval", isWaiting: true,
                stateAt: now - 70, now: now
            ))
            VStack(spacing: Spacing.medium) {
                ChatBubble(
                    role: .agent,
                    text: "The redirect loop comes from the cookie path. I fixed `auth/session.go` and want to run the package tests."
                )
                InlinePermissionCard(toolName: "Bash", summary: "go test ./internal/billing/... -run Redirect", onAllow: {}, onDeny: {})
                InlineAskCard(
                    askID: 110, kind: "question", title: "Keep the old /login path as an alias?",
                    options: [
                        InlineAskOption(id: "a", label: "Yes, for 30 days", isRecommended: true),
                        InlineAskOption(id: "b", label: "No, remove it")
                    ],
                    onPick: { _ in }, onOpen: {}
                )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            WorkchatComposerBar(text: .constant(""), mode: .answerAbove) {}
        }
    }

    /// Mockup 8: the Mac asleep, the state "as of", a line waiting for it.
    static var workchatAsleepPage: some View {
        Page(title: "acme") {
            chatHeader("Session report", StateLineModel(
                glyph: nil, tone: .green, caption: "Working", isWaiting: false, stateAt: now - 3_000, now: now, asOf: now - 720
            ))
            MacStatusChip(model: MacStatusChipModel(macName: "MacBook Pro", state: .asleep(lastSeen: now - 720), now: now))
            VStack(spacing: Spacing.medium) {
                ChatBubble(role: .agent, text: "All 42 tests pass. Next I'll update the Desktop card so the link opens in the browser.")
                ChatBubble(role: .owner, text: "Ship it when the card is done.", caption: "Waiting for your Mac", isPending: true)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            WorkchatComposerBar(text: .constant("Also bump the version"), mode: .message, note: "New lines go when your Mac wakes.") {}
        }
    }

    /// Mockup 5: board cards in lanes, one selected.
    static var boardPage: some View {
        Page(title: "Board") {
            SectionHeader("In progress", count: 2).padding(.horizontal, -Spacing.large)
            BoardCard(model: BoardCardModel(
                number: 1, title: "Billing export for acme", status: .inProgress, statusText: "In Progress",
                priority: .high, counter: "1/2", progress: 0.55
            ))
            BoardCard(model: BoardCardModel(
                number: 343, title: "Session report", status: .inProgress, statusText: "In Progress", priority: .medium, liveSessions: 1
            ))
            SectionHeader("Blocked", count: 1).padding(.horizontal, -Spacing.large)
            BoardCard(model: BoardCardModel(number: 5, title: "Invoice PDF layout", status: .blocked, statusText: "Blocked", priority: .medium))
            SectionHeader("To Do", count: 3).padding(.horizontal, -Spacing.large)
            BoardCard(
                model: BoardCardModel(number: 4, title: "Fix the login redirect", status: .todo, statusText: "To Do", priority: .low),
                isSelected: true
            )
            BoardCard(
                model: BoardCardModel(number: 2, title: "Nightly export", status: .done, statusText: "Done", priority: .low, progress: 1),
                isDimmed: true
            )
        }
    }

    /// Mockup 7: calendar rows, past, now, next and later.
    static var calendarPage: some View {
        Page(title: "Calendar") {
            MacStatusChip(model: MacStatusChipModel(macName: "MacBook Pro", state: .online, now: now))
            CalendarRow(model: CalendarRowModel(
                start: now - 14_700, end: now - 11_100, title: "acme weekly sync", location: "Room 2", attendees: 6,
                recordings: 1, isNext: false, now: now
            ))
            CalendarRow(model: CalendarRowModel(
                start: now - 780, end: now + 1_920, title: "Billing export review", location: "meet.example.com",
                attendees: 3, isNext: false, now: now
            ))
            CalendarRow(model: CalendarRowModel(
                start: now + 1_500, end: now + 3_300, title: "Design critique", attendees: 4, isNext: true, now: now
            ))
            CalendarRow(model: CalendarRowModel(
                start: now + 6_900, end: now + 8_700, title: "1:1 colleague A", location: "Zoom", isNext: false, now: now
            ))
        }
    }

    /// Mockup 16: grouped settings with small switches and a footer.
    static var settingsPage: some View {
        Page(title: "Settings") {
            SettingsCard(title: "This Mac") {
                SettingsRow(title: "MacBook Pro") { Text("Online") }
                CardRowDivider()
                SettingsRow(title: "Last sync") { Text("just now") }
                CardRowDivider()
                SettingsRow(title: "Macs") { Text("2 ›") }
            }
            SettingsCard(title: "Workbench") {
                SettingsRow(title: "Type into sessions") { Toggle("", isOn: .constant(true)).toggleStyle(SmallSwitchStyle()) }
                CardRowDivider()
                SettingsRow(title: "Answer permission prompts") { Toggle("", isOn: .constant(true)).toggleStyle(SmallSwitchStyle()) }
                CardRowDivider()
                SettingsRow(title: "Start sessions") { Toggle("", isOn: .constant(false)).toggleStyle(SmallSwitchStyle()) }
            }
            SettingsCard(
                title: "Notifications",
                footer: "Asks, approvals and finished or failed sessions, only while you’re away from your Mac."
            ) {
                SettingsRow(title: "When work stops") { Toggle("", isOn: .constant(true)).toggleStyle(SmallSwitchStyle()) }
            }
        }
    }

    /// Mockups 9–12: pills, state marks and the two bars.
    static var actionsPage: some View {
        Page(title: "Parts") {
            SectionHeader("Pills").padding(.horizontal, -Spacing.large)
            FlowRow {
                Pill(item: PillItem(text: "High", tone: .red, dot: true))
                Pill(item: PillItem(text: "Low", tone: .blue, dot: true))
                Pill(text: "In Review", tone: .teal)
                Pill(text: "Snoozed", tone: .purple)
                Pill(text: "feature/session-report", style: .neutral, monospaced: true)
                CountBadge(count: 3, tone: .waitingForYou)
            }
            SectionHeader("Marks").padding(.horizontal, -Spacing.large)
            HStack(spacing: Spacing.medium) {
                StateMark(glyph: "questionmark", tone: .waitingForYou)
                StateMark(glyph: "hand.raised.fill", tone: .waitingForYou)
                StateMark(glyph: "checklist", tone: .purple)
                StateMark(glyph: "checkmark", tone: .blue)
                SessionDot(tone: .green, isRing: false)
                SessionDot(tone: .secondary, isRing: true)
            }
            SectionHeader("Steps").padding(.horizontal, -Spacing.large)
            StepRow(state: .done, text: "Lock the Mac and wait for the ask push")
            StepRow(state: .failed, text: "Answer it from the lock screen")
            Text("Target detail: one prominent action").font(TypeScale.meta).foregroundStyle(.secondary)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                PrimaryActionBar(primary: BarAction(title: "Approve") {}, secondary: BarAction(title: "Request changes") {})
                PrimaryActionBar(primary: BarAction(title: "Start a session") {})
            }
        }
    }
}

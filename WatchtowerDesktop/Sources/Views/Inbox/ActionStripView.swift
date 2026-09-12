import SwiftUI
import WatchtowerCore

/// The Inbox tab's content: a flat strip of due reminders and pending agent-
/// action proposals — the reaction-command surface, replacing the situations
/// Dashboard (`InboxFeedView`, which stays in place for the demolition
/// follow-up to remove). The Dashboard's two sibling tabs did not move with
/// it: the learned-rules manager and the assistant profile editor still feed
/// triage, so they keep their door here behind the same segmented control
/// `InboxFeedView` had (`.learned`/`.profile` render the very same views).
/// Reads `appState.actionStripViewModel` (AppState-owned so it survives
/// navigation, the `SlackAccountsViewModel` house pattern) and
/// re-`refresh()`s on every appear — cross-process daemon/CLI writes don't
/// fire `ValueObservation` (see the view model's own doc comment).
struct ActionStripView: View {
    @Environment(AppState.self) private var appState
    @State private var tab: Tab = .actions

    enum Tab { case actions, learned, profile }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Actions").tag(Tab.actions)
                Text("Learned").tag(Tab.learned)
                Text("Profile").tag(Tab.profile)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            switch tab {
            case .actions:
                if let vm = appState.actionStripViewModel {
                    content(vm)
                } else {
                    ProgressView()
                }
            case .learned:
                if let dbPool = appState.databaseManager?.dbPool {
                    InboxLearnedRulesView(db: dbPool)
                } else {
                    unavailable
                }
            case .profile:
                if let vm = appState.secretaryProfileViewModel {
                    SecretaryProfileView(vm: vm)
                } else {
                    unavailable
                }
            }
        }
        .navigationTitle("Inbox")
        .task { appState.actionStripViewModel?.refresh() }
    }

    private var unavailable: some View {
        Text("Database unavailable")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func content(_ vm: ActionStripViewModel) -> some View {
        VStack(spacing: 0) {
            if let message = vm.lastError {
                errorBanner(message)
            }
            if vm.actionRows.isEmpty && vm.reminderRows.isEmpty {
                ContentUnavailableView("Nothing waiting on you", systemImage: "tray")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !vm.reminderRows.isEmpty {
                        Section("Reminders") {
                            ForEach(vm.reminderRows) { reminder in
                                ReminderRow(reminder: reminder, vm: vm)
                            }
                        }
                    }
                    if !vm.actionRows.isEmpty {
                        Section("Proposals") {
                            ForEach(vm.actionRows) { action in
                                AgentActionCardView(
                                    action: action,
                                    inFlight: vm.actionFeed.inFlight.contains(action.id),
                                    onApprove: { Task { await vm.approve(action.id) } },
                                    onReject: { Task { await vm.reject(action.id) } },
                                    onRetry: { Task { await vm.retry(action.id) } }
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    /// The `IdeasView`/`DashboardView` house pattern: a write failure
    /// otherwise vanishes into `vm.lastError` with nothing rendering it.
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}

/// One due reminder: its note, the Slack message it was set from (rendered
/// as its raw `<channel_id>@<message_ts>` ref — the reminder row carries no
/// joined permalink to turn it into a real link), and Done / Snooze 1h.
private struct ReminderRow: View {
    let reminder: Reminder
    let vm: ActionStripViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(reminder.note.isEmpty ? "Reminder" : reminder.note)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if !reminder.messageRef.isEmpty {
                    Text(reminder.messageRef)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Done") { vm.markReminderDone(reminder.id) }
            Button("Snooze 1h") {
                let until = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
                vm.snoozeReminder(reminder.id, until: until)
            }
        }
        .padding(.vertical, 4)
    }
}

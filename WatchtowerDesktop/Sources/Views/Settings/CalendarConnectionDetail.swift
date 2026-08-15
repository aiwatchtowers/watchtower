import SwiftUI
import WatchtowerCore

/// Calendar detail pane in the Connections tab — the multi-account CalDAV/ICS
/// connections, distinct from Google Calendar's connections in
/// `GoogleConnectionDetail`, plus per-calendar sync selection across every
/// connected account.
struct CalendarConnectionDetail: View {
    @Environment(AppState.self) private var appState
    @State private var showAddCalendarAccountSheet = false
    @State private var calendarAccountPendingRemoval: CalendarAccount?

    var body: some View {
        Form {
            calendarAccountsSection
            calendarSelectionSection
        }
        .formStyle(.grouped)
        .padding(.horizontal)
        .padding(.top, 4)
    }

    /// Calendar Accounts section — the multi-account CalDAV/ICS connections,
    /// distinct from Google Calendar's connections. Each row is a DB row
    /// (`calendar_accounts`), so status can be ok/error per account rather
    /// than a single connected/disconnected flag.
    private var calendarAccountsSection: some View {
        Section("Calendar Accounts") {
            if let vm = appState.calendarAccountsViewModel {
                if vm.accounts.isEmpty {
                    Text("No CalDAV or ICS calendars connected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vm.accounts) { account in
                        HStack {
                            Image(systemName: account.isICS ? "link" : "server.rack")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(account.displayName)
                                Text(account.isICS ? "ICS feed" : "CalDAV \u{00B7} \(account.url)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Circle()
                                .fill(account.isOK ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Button("Remove") {
                                calendarAccountPendingRemoval = account
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                        }
                    }
                }

                if let err = vm.error {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button("Add Calendar") {
                    showAddCalendarAccountSheet = true
                }
            } else {
                Text("Loading...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showAddCalendarAccountSheet) {
            AddCalendarAccountView()
                .environment(appState)
        }
        .confirmationDialog(
            "Remove \(calendarAccountPendingRemoval?.displayName ?? "this calendar")?",
            isPresented: Binding(
                get: { calendarAccountPendingRemoval != nil },
                set: { if !$0 { calendarAccountPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Calendar", role: .destructive) {
                if let account = calendarAccountPendingRemoval {
                    Task { await appState.calendarAccountsViewModel?.remove(account) }
                }
                calendarAccountPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Removes the connection and stops syncing this calendar. "
                    + "Already-synced events and AI products built on them are kept."
            )
        }
    }

    /// Per-calendar sync selection — the Desktop twin of `watchtower calendar
    /// select <id>`. Grouped under one Section per connected Google account
    /// (using `GoogleAccountsViewModel.accounts` for the header label) plus a
    /// trailing group for CalDAV/ICS calendars (`account_id IS NULL`), so a
    /// multi-account workspace can tell which calendar belongs to which
    /// connection. `@ViewBuilder` because the group count varies with how
    /// many accounts have synced calendars — unlike this file's other
    /// section properties, which always render exactly one `Section`.
    @ViewBuilder
    private var calendarSelectionSection: some View {
        if let calVM = appState.calendarViewModel, !calVM.calendars.isEmpty {
            ForEach(appState.googleAccountsViewModel?.accounts ?? []) { account in
                let calendars = calVM.calendars.filter { $0.accountID == account.id }
                if !calendars.isEmpty {
                    Section("Calendars \u{00B7} \(account.displayName)") {
                        calendarSelectionRows(calendars, calVM: calVM)
                    }
                }
            }
            let otherCalendars = calVM.calendars.filter { $0.accountID == nil }
            if !otherCalendars.isEmpty {
                Section("Calendars \u{00B7} CalDAV/ICS") {
                    calendarSelectionRows(otherCalendars, calVM: calVM)
                }
            }
        } else {
            Section("Synced Calendars") {
                Text("No calendars synced yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func calendarSelectionRows(_ calendars: [CalendarCalendarItem], calVM: CalendarViewModel) -> some View {
        ForEach(calendars) { cal in
            Toggle(isOn: Binding(
                get: { cal.isSelected },
                set: { calVM.setCalendarSelected(cal.id, selected: $0) }
            )) {
                HStack(spacing: 4) {
                    Text(cal.name)
                    if cal.isPrimary {
                        Text("Primary")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

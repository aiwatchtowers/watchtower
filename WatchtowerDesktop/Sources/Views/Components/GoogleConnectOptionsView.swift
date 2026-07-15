import SwiftUI

/// Pre-checked scope picker for the Google connect flow — shown on the
/// Calendar tab's empty state and in the Inbox connect popover. Only the
/// still-disconnected services are listed; unchecking one skips its OAuth
/// request entirely (Google's own consent screen cannot pre-select scopes,
/// so the selection happens here).
struct GoogleConnectOptionsView: View {
    @Bindable var flow: GoogleConnectFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !flow.calendar.isConnected {
                Toggle(isOn: $flow.includeCalendar) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Google Calendar")
                        Text("Upcoming meetings, prep, and briefings")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !flow.gmail.isConnected {
                Toggle(isOn: $flow.includeGmail) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Gmail")
                        Text("Inbox emails in the secretary feed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .toggleStyle(.checkbox)
    }
}

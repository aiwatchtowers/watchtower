import SwiftUI

/// Pre-checked scope picker for the Google connect flow — shown on the
/// Calendar tab's empty state and in the Inbox connect popover. Only the
/// still-disconnected services are listed; unchecking one skips its OAuth
/// request entirely (Google's own consent screen cannot pre-select scopes,
/// so the selection happens here).
struct GoogleConnectOptionsView: View {
    @Bindable var flow: GoogleConnectFlow
    /// Whether to offer the Gmail toggle at all — the Calendar tab's connect
    /// screen is calendar-only and must never request the Gmail scope, even
    /// though it shares this view (and `flow`) with the Inbox banner, which
    /// does want Gmail offered. Defaults to true for the Inbox banner's call
    /// site.
    var showGmail: Bool = true

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
            if showGmail && !flow.gmail.isConnected {
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
        // `flow` is a shared singleton (GoogleConnectFlow.shared) reused by
        // both call sites — force includeGmail off here so a calendar-only
        // "Connect Google" tap can never silently request the Gmail scope,
        // regardless of whatever the OTHER call site last left it as.
        .onAppear { if !showGmail { flow.includeGmail = false } }
    }
}

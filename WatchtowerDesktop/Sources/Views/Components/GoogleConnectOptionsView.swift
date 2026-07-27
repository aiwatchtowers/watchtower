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
    /// otherwise wants Gmail offered. Defaults to
    /// `Constants.gmailOAuthAvailable` so every call site automatically
    /// respects that flag without having to remember to pass it.
    var showGmail: Bool = Constants.gmailOAuthAvailable

    private var showCalendarOption: Bool { !flow.calendar.isConnected }
    private var showGmailOption: Bool { showGmail && !flow.gmail.isConnected }

    /// A checkbox only makes sense when there's an actual choice — one item
    /// out of several to opt out of. With exactly one item visible (the
    /// common case right now, since Gmail is hidden while
    /// `Constants.gmailOAuthAvailable` is false) there is nothing to choose:
    /// render it as plain, non-interactive info and force it selected,
    /// instead of a checkbox the user could confusingly uncheck to disable
    /// the very thing this screen exists to connect.
    private var singleOption: Bool {
        (showCalendarOption ? 1 : 0) + (showGmailOption ? 1 : 0) == 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showCalendarOption {
                optionRow(
                    title: "Google Calendar",
                    subtitle: "Upcoming meetings, prep, and briefings",
                    isOn: $flow.includeCalendar
                )
            }
            if showGmailOption {
                optionRow(
                    title: "Gmail",
                    subtitle: "Inbox emails in the secretary feed",
                    isOn: $flow.includeGmail
                )
            }
        }
        .toggleStyle(.checkbox)
        .onAppear {
            // `flow` is a shared singleton (GoogleConnectFlow.shared) reused
            // by both call sites — force includeGmail off here so a
            // calendar-only "Connect Google" tap can never silently request
            // the Gmail scope, regardless of whatever the OTHER call site
            // last left it as.
            if !showGmail { flow.includeGmail = false }
            // A single visible option is implicitly wanted — force it on
            // rather than leaving it opt-out-able via a pointless checkbox.
            if singleOption {
                if showCalendarOption { flow.includeCalendar = true }
                if showGmailOption { flow.includeGmail = true }
            }
        }
    }

    @ViewBuilder
    private func optionRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        let label = VStack(alignment: .leading, spacing: 1) {
            Text(title)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if singleOption {
            label
        } else {
            Toggle(isOn: isOn) { label }
        }
    }
}

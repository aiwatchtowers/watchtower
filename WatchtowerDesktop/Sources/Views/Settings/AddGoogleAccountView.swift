import DesignKit
import SwiftUI
import WatchtowerCore

/// Sheet for connecting a new Google account through Watchtower's baked
/// Google client, presented from Connections → Calendar, onboarding and —
/// on a flavored build — Email's Connect Gmail. Unlike the IMAP/CalDAV "Add"
/// sheets, there's only one provider here — Google — so this is a single
/// form rather than a stack of provider cards. A project of the person's own
/// is the Google detail's **Use my own Google project** page (#1887 C4,
/// which replaced this sheet's "Advanced: custom OAuth client"; the CLI's
/// `--client-id` stays). On the public build that client is Watchtower's
/// shared app, which asks for Calendar only (D11): Gmail stays off and the
/// note says where it connects instead; Go refuses a Gmail ask there anyway.
struct AddGoogleAccountView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private var vm: GoogleAccountsViewModel? { appState.googleAccountsViewModel }
    private typealias Copy = AddGoogleAccountCopy

    /// `.deferred` from onboarding: the connect must not restart the daemon
    /// mid-setup (`DaemonRestartPolicy`). Settings keeps the default.
    let daemonPolicy: DaemonRestartPolicy
    /// The build's client may ask for Gmail (a flavored build).
    let offersGmail: Bool

    init(
        daemonPolicy: DaemonRestartPolicy = .restart,
        offersGmail: Bool = CompanyConnectionsPresentation.sharedGoogleOffersGmail(
            buildFlavor: CompanyBridgeLaunch.bundleFlavor)
    ) {
        self.daemonPolicy = daemonPolicy
        self.offersGmail = offersGmail
        let scopes = Self.initialScopes(offersGmail: offersGmail)
        _wantCalendar = State(initialValue: scopes.calendar)
        _wantGmail = State(initialValue: scopes.gmail)
    }

    /// The sheet opens with every service its client may ask for checked, on
    /// every surface, onboarding included; either can be unchecked (#740).
    /// The shared app asks for Calendar only (D11).
    static func initialScopes(offersGmail: Bool) -> (calendar: Bool, gmail: Bool) {
        (calendar: true, gmail: offersGmail)
    }

    @State private var wantCalendar: Bool
    @State private var wantGmail: Bool
    /// Set when Connect is tapped from THIS sheet, cleared on Cancel or once
    /// consumed by `onChange` below — guards the auto-dismiss so it only
    /// fires for a connect attempt this sheet actually started, not some
    /// unrelated `isConnecting` flip (e.g. another sheet's attempt finishing
    /// while this one happens to still be around).
    @State private var connectAttempted = false

    /// Gmail is asked for only where the client may ask for it.
    private var gmail: Bool { offersGmail && wantGmail }
    private var canConnect: Bool { wantCalendar || gmail }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(Copy.title)
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button(Copy.close) { dismiss() }
                    .buttonStyle(.plain)
            }

            Toggle(Copy.calendar, isOn: $wantCalendar)
            Toggle(Copy.gmail, isOn: $wantGmail)
                .disabled(!offersGmail)
            if !offersGmail {
                Text(CompanyConnectionsPresentation.sharedGoogleGmailNote(locks: appState.companyLocks))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            HStack {
                if vm?.isConnecting == true {
                    ProgressView().controlSize(.small)
                    Text(Copy.connecting)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(Copy.cancel) {
                        // Clear the flag first so the onChange below sees this
                        // as a user-cancelled attempt and does NOT auto-dismiss
                        // — Cancel means "let me adjust the form", not "close it".
                        connectAttempted = false
                        vm?.cancelConnect()
                    }
                } else {
                    Spacer()
                    Button(Copy.connect) {
                        connect()
                    }
                    .buttonStyle(.kitPrimary)
                    .disabled(!canConnect)
                }
            }

            if let err = vm?.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(Tone.error)
                    .textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: 480, height: 420)
        .onChange(of: vm?.isConnecting) { oldValue, newValue in
            // addAccount() is fire-and-forget (unlike addCalDAV/addICS/
            // addImapAccount, which are awaited and dismiss() directly on
            // success) — isConnecting flipping true -> false is the only
            // completion signal, so mirror those siblings' "dismiss on
            // success, stay open with the error otherwise" behavior here.
            guard connectAttempted, oldValue == true, newValue == false else { return }
            connectAttempted = false
            if vm?.error == nil {
                dismiss()
            }
        }
    }

    private func connect() {
        // Only arm the auto-dismiss guard when addAccount() actually started
        // a connection — its own early-return guards (already connecting, no
        // CLI found) return false without ever flipping isConnecting, so the
        // onChange below would otherwise wait for a true→false transition
        // that will never come from this attempt.
        connectAttempted = vm?.addAccount(
            calendar: wantCalendar,
            gmail: gmail,
            clientID: "",
            clientSecret: "",
            daemonPolicy: daemonPolicy
        ) ?? false
    }
}

import SwiftUI

/// Sheet for connecting a new Google account (Calendar and/or Gmail),
/// presented from Settings → Google Accounts. Unlike the IMAP/CalDAV "Add"
/// sheets, there's only one provider here — Google — so this is a single
/// form rather than a stack of provider cards.
struct AddGoogleAccountView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private var vm: GoogleAccountsViewModel? { appState.googleAccountsViewModel }

    @State private var label = ""
    @State private var wantCalendar = true
    @State private var wantGmail = true
    @State private var showAdvanced = false
    @State private var clientID = ""
    @State private var clientSecret = ""
    /// Set when Connect is tapped from THIS sheet, cleared on Cancel or once
    /// consumed by `onChange` below — guards the auto-dismiss so it only
    /// fires for a connect attempt this sheet actually started, not some
    /// unrelated `isConnecting` flip (e.g. another sheet's attempt finishing
    /// while this one happens to still be around).
    @State private var connectAttempted = false

    /// Custom-client fields must be BOTH empty or BOTH set — a secret typed
    /// with no client ID would otherwise be silently dropped: `addAccount`
    /// only treats the pair as a custom client when `clientID` is non-empty
    /// (`hasCustomClient = !clientID.isEmpty`), so a lone secret gets thrown
    /// away and the account connects with the build-time default OAuth
    /// client instead, with no signal to the user that their secret was ignored.
    private var customClientFieldsConsistent: Bool {
        clientID.isEmpty == clientSecret.isEmpty
    }

    private var canConnect: Bool {
        (wantCalendar || wantGmail) && customClientFieldsConsistent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Add Google Account")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
            }

            TextField("Label (optional)", text: $label, prompt: Text("e.g. Work, Personal"))
                .textFieldStyle(.roundedBorder)

            Toggle("Calendar", isOn: $wantCalendar)
            Toggle("Gmail", isOn: $wantGmail)

            DisclosureGroup("Advanced: custom OAuth client", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Client ID", text: $clientID)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Client secret", text: $clientSecret)
                        .textFieldStyle(.roundedBorder)
                    if !clientSecret.isEmpty && clientID.isEmpty {
                        Text("Client ID is required when a secret is provided.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Text("Needed when this account belongs to a different Google Workspace org than the built-in app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }

            Spacer()

            HStack {
                if vm?.isConnecting == true {
                    ProgressView().controlSize(.small)
                    Text("Connecting...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") {
                        // Clear the flag first so the onChange below sees this
                        // as a user-cancelled attempt and does NOT auto-dismiss
                        // — Cancel means "let me adjust the form", not "close it".
                        connectAttempted = false
                        vm?.cancelConnect()
                    }
                } else {
                    Spacer()
                    Button("Connect") {
                        connect()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConnect)
                }
            }

            if let err = vm?.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
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
            label: label.trimmingCharacters(in: .whitespaces),
            calendar: wantCalendar,
            gmail: wantGmail,
            clientID: clientID.trimmingCharacters(in: .whitespaces),
            clientSecret: clientSecret
        ) ?? false
    }
}

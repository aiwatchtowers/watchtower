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

    private var canConnect: Bool {
        (wantCalendar || wantGmail)
            && (clientID.isEmpty || !clientSecret.isEmpty)
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
                    Button("Cancel") { vm?.cancelConnect() }
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
    }

    private func connect() {
        vm?.addAccount(
            label: label.trimmingCharacters(in: .whitespaces),
            calendar: wantCalendar,
            gmail: wantGmail,
            clientID: clientID.trimmingCharacters(in: .whitespaces),
            clientSecret: clientSecret
        )
    }
}

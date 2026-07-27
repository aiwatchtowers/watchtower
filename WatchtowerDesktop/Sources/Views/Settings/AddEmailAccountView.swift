import SwiftUI

/// Sheet for connecting a new email source, presented from the Settings →
/// Email Accounts section. Three provider cards:
///  - Gmail: the EXISTING single-account OAuth flow (`GoogleConnectFlow.shared.gmail`),
///    reused as-is — this view adds no Gmail logic of its own.
///  - Outlook: OAuth via `EmailAccountsViewModel.connectOutlook`, same loopback-
///    browser flow shape as Gmail but multi-account.
///  - IMAP: a host/port/credentials form; the password is written to the
///    `imap add` subprocess's stdin, never passed as a flag.
struct AddEmailAccountView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private var google: GoogleConnectFlow { GoogleConnectFlow.shared }
    private var vm: EmailAccountsViewModel? { appState.emailAccountsViewModel }

    // MARK: - IMAP form state

    @State private var host = ""
    @State private var portText = "993"
    @State private var security: IMAPSecurity = .ssl
    @State private var username = ""
    @State private var password = ""
    @State private var folder = "INBOX"
    @State private var label = ""
    @State private var isConnectingIMAP = false
    @State private var imapError: String?

    // MARK: - Outlook form state

    @State private var outlookLabel = ""

    enum IMAPSecurity: String, CaseIterable, Identifiable {
        case ssl, starttls, none

        var id: String { rawValue }

        var displayLabel: String {
            switch self {
            case .ssl: return "SSL"
            case .starttls: return "STARTTLS"
            case .none: return "None"
            }
        }
    }

    private var port: Int? { Int(portText) }

    private var canConnectIMAP: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && port != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Add Email Account")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    gmailCard
                    outlookCard
                    imapCard
                }
                .padding(.bottom, 8)
            }
        }
        .padding(20)
        .frame(width: 480, height: 640)
        .onAppear {
            google.refresh()
        }
    }

    // MARK: - Gmail card

    private var gmailCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "envelope.fill")
                    Text("Gmail")
                        .font(.headline)
                    Spacer()
                }
                Text("Google's own OAuth flow — a single Gmail account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if google.gmail.isConnected {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if google.gmail.isAuthenticating {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Connecting...")
                        Spacer()
                        Button("Cancel") { google.gmail.cancelConnect() }
                    }
                } else if !Constants.gmailOAuthAvailable {
                    Label(
                        "Temporarily unavailable (pending Google verification) — use IMAP with an app password instead.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Button("Connect Gmail") {
                        google.gmail.connect()
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let err = google.gmail.error {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    // MARK: - Outlook card

    private var outlookCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "envelope.badge.fill")
                    Text("Outlook")
                        .font(.headline)
                    Spacer()
                }
                Text("Microsoft OAuth — supports multiple Outlook accounts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Label (optional)", text: $outlookLabel)
                    .textFieldStyle(.roundedBorder)

                if vm?.isRunning == true {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Connecting...")
                        Spacer()
                        Button("Cancel") { vm?.cancelConnect() }
                    }
                } else {
                    Button("Connect Outlook") {
                        vm?.connectOutlook(label: outlookLabel)
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let err = vm?.error {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    // MARK: - IMAP card

    private var imapCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "server.rack")
                    Text("IMAP")
                        .font(.headline)
                    Spacer()
                }
                Text("Any IMAP mailbox — host, port, and folder configured manually.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Host", text: $host, prompt: Text("imap.example.com"))
                    .textFieldStyle(.roundedBorder)

                HStack {
                    TextField("Port", text: $portText, prompt: Text("993"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)

                    Picker("", selection: $security) {
                        ForEach(IMAPSecurity.allCases) { option in
                            Text(option.displayLabel).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                TextField("Username", text: $username, prompt: Text("you@example.com"))
                    .textFieldStyle(.roundedBorder)

                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)

                TextField("Folder", text: $folder, prompt: Text("INBOX"))
                    .textFieldStyle(.roundedBorder)

                TextField("Label (optional)", text: $label)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    if isConnectingIMAP {
                        ProgressView().controlSize(.small)
                        Text("Connecting...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Test and Connect") {
                        connectIMAP()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConnectIMAP || isConnectingIMAP)
                }

                if let err = imapError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func connectIMAP() {
        guard let port, let vm else { return }
        isConnectingIMAP = true
        imapError = nil
        let hostValue = host.trimmingCharacters(in: .whitespaces)
        let usernameValue = username.trimmingCharacters(in: .whitespaces)
        let folderValue = folder.trimmingCharacters(in: .whitespaces)
        let labelValue = label.trimmingCharacters(in: .whitespaces)
        let passwordValue = password
        Task {
            let success = await vm.addImapAccount(
                host: hostValue,
                port: port,
                username: usernameValue,
                password: passwordValue,
                folder: folderValue.isEmpty ? "INBOX" : folderValue,
                security: security.rawValue,
                label: labelValue
            )
            isConnectingIMAP = false
            if success {
                dismiss()
            } else {
                imapError = vm.error
            }
        }
    }
}

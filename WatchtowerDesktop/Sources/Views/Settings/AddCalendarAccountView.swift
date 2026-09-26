import SwiftUI

/// Sheet for connecting a new calendar source, presented from the Settings →
/// Calendar Accounts section and the Calendar tab's not-connected screen.
/// Three provider cards:
///  - Google: redirects to the multi-account `AddGoogleAccountView` sheet
///    (Settings → Google Accounts) — this view adds no Google logic of its own.
///  - CalDAV: a server URL/credentials form; the app password is written to the
///    `caldav add` subprocess's stdin, never passed as a flag.
///  - ICS: a secret feed link (e.g. Google Calendar's "Secret address in iCal
///    format"); the link is a credential — stdin only, never argv, never in
///    any assistant snapshot.
struct AddCalendarAccountView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private var vm: CalendarAccountsViewModel? { appState.calendarAccountsViewModel }

    @State private var showAddGoogleAccountSheet = false

    // MARK: - CalDAV form state

    @State private var caldavURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var caldavLabel = ""
    @State private var isConnectingCalDAV = false
    @State private var caldavError: String?

    // MARK: - ICS form state

    @State private var feedURL = ""
    @State private var icsLabel = ""
    @State private var isConnectingICS = false
    @State private var icsError: String?

    // MARK: - Setup assistant state

    @State private var showAssistant = false
    @State private var setupChatVM: CalendarSetupChatViewModel?
    @State private var showAssistantFilledNote = false
    @State private var assistantFilledNoteToken = 0

    private var canConnectCalDAV: Bool {
        !caldavURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
    }

    private var canConnectICS: Bool {
        !feedURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Add Calendar")
                        .font(.title2)
                        .fontWeight(.bold)
                    Spacer()
                    Button("Close") { dismiss() }
                        .buttonStyle(.plain)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        googleCard
                        caldavCard
                        icsCard
                    }
                    .padding(.bottom, 8)
                }
            }
            .frame(width: 440)

            if showAssistant, let chatVM = setupChatVM {
                Divider()
                    .padding(.leading, 16)
                CalendarSetupAssistantPanel(
                    chatVM: chatVM,
                    makeSnapshot: { formSnapshot() },
                    onClose: { withAnimation(.easeInOut(duration: 0.2)) { showAssistant = false } }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(width: showAssistant ? 860 : 480, height: 640)
    }

    // MARK: - Google card

    private var googleCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "calendar")
                    Text("Google Calendar")
                        .font(.headline)
                    Spacer()
                }
                Text("Google's OAuth flow — supports multiple Google accounts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Connect Google Calendar") {
                    showAddGoogleAccountSheet = true
                }
                .buttonStyle(.borderedProminent)

                Text("No Google sign-in? The ICS card below works with Google Calendar's "
                    + "\"Secret address in iCal format\" — no OAuth needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .sheet(isPresented: $showAddGoogleAccountSheet) {
            AddGoogleAccountView()
                .environment(appState)
        }
    }

    // MARK: - CalDAV card

    private var caldavCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "server.rack")
                    Text("CalDAV")
                        .font(.headline)
                    Spacer()
                    Button {
                        toggleAssistant()
                    } label: {
                        Label("Help me set this up", systemImage: "sparkles")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Chat with an assistant that fills in these settings for you")
                }
                Text("iCloud, Fastmail, Yandex, Nextcloud, or any CalDAV server — "
                    + "username plus an app password.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Server URL", text: $caldavURL, prompt: Text("https://caldav.icloud.com"))
                    .textFieldStyle(.roundedBorder)

                TextField("Username", text: $username, prompt: Text("you@example.com"))
                    .textFieldStyle(.roundedBorder)

                SecureField("App password", text: $password)
                    .textFieldStyle(.roundedBorder)

                TextField("Label (optional)", text: $caldavLabel)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    if isConnectingCalDAV {
                        ProgressView().controlSize(.small)
                        Text("Connecting...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Test and Connect") {
                        connectCalDAV()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConnectCalDAV || isConnectingCalDAV)
                }

                if showAssistantFilledNote {
                    Label("Assistant filled in the settings", systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .transition(.opacity)
                }

                if let err = caldavError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    if !showAssistant {
                        Button {
                            askAssistantAboutError(err)
                        } label: {
                            Label("Ask the assistant about this error", systemImage: "sparkles")
                                .font(.caption)
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    // MARK: - ICS card

    private var icsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "link")
                    Text("ICS link")
                        .font(.headline)
                    Spacer()
                }
                Text("Paste the private iCal/ICS address of your calendar — "
                    + "e.g. Google Calendar's \"Secret address in iCal format\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // The feed URL is a credential: it goes to the CLI via stdin
                // and NEVER enters an assistant snapshot (only hasFeedURL does).
                TextField("Secret feed URL", text: $feedURL, prompt: Text("https://calendar.google.com/calendar/ical/…"))
                    .textFieldStyle(.roundedBorder)

                TextField("Label (optional)", text: $icsLabel)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    if isConnectingICS {
                        ProgressView().controlSize(.small)
                        Text("Connecting...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Connect") {
                        connectICS()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConnectICS || isConnectingICS)
                }

                if let err = icsError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    if !showAssistant {
                        Button {
                            askAssistantAboutError(err)
                        } label: {
                            Label("Ask the assistant about this error", systemImage: "sparkles")
                                .font(.caption)
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    // MARK: - Setup assistant wiring

    /// What the assistant is allowed to see. PRIVACY: `CalendarFormSnapshot`
    /// has no password slot and no feed-URL slot — only `hasPassword` /
    /// `hasFeedURL` — so neither credential can ever reach a prompt from here.
    private func formSnapshot() -> CalendarFormSnapshot {
        CalendarFormSnapshot(
            caldavURL: caldavURL,
            username: username,
            label: caldavLabel,
            hasPassword: !password.isEmpty,
            hasFeedURL: !feedURL.isEmpty,
            lastConnectionError: caldavError ?? icsError
        )
    }

    private func toggleAssistant() {
        if showAssistant {
            withAnimation(.easeInOut(duration: 0.2)) { showAssistant = false }
        } else {
            openAssistant()
        }
    }

    private func openAssistant() {
        if setupChatVM == nil {
            let vm = CalendarSetupChatViewModel()
            vm.onApplySettings = { patch in applyAssistantSettings(patch) }
            setupChatVM = vm
        }
        setupChatVM?.seedGreetingIfNeeded()
        withAnimation(.easeInOut(duration: 0.2)) { showAssistant = true }
    }

    /// Writes an assistant patch into the CalDAV form fields. The patch type
    /// carries only url/username, so the SecureField and the ICS feed field
    /// stay 100% manual.
    private func applyAssistantSettings(_ patch: CalendarSettingsPatch) {
        if let value = patch.url { caldavURL = value }
        if let value = patch.username { username = value }

        assistantFilledNoteToken += 1
        let token = assistantFilledNoteToken
        withAnimation { showAssistantFilledNote = true }
        Task {
            try? await Task.sleep(for: .seconds(4))
            if token == assistantFilledNoteToken {
                withAnimation { showAssistantFilledNote = false }
            }
        }
    }

    private func askAssistantAboutError(_ error: String) {
        openAssistant()
        setupChatVM?.sendConnectionError(error, snapshot: formSnapshot())
    }

    private func connectCalDAV() {
        guard let vm else { return }
        isConnectingCalDAV = true
        caldavError = nil
        let urlValue = caldavURL.trimmingCharacters(in: .whitespaces)
        let usernameValue = username.trimmingCharacters(in: .whitespaces)
        let labelValue = caldavLabel.trimmingCharacters(in: .whitespaces)
        let passwordValue = password
        Task {
            let success = await vm.addCalDAV(
                url: urlValue,
                username: usernameValue,
                password: passwordValue,
                label: labelValue
            )
            isConnectingCalDAV = false
            if success {
                dismiss()
            } else {
                caldavError = vm.error
                // With the assistant open, hand it the failure right away so
                // it can explain the error in plain words (snapshot only —
                // never the password value).
                if showAssistant, let err = caldavError, let chatVM = setupChatVM {
                    chatVM.sendConnectionError(err, snapshot: formSnapshot())
                }
            }
        }
    }

    private func connectICS() {
        guard let vm else { return }
        isConnectingICS = true
        icsError = nil
        let feedValue = feedURL.trimmingCharacters(in: .whitespaces)
        let labelValue = icsLabel.trimmingCharacters(in: .whitespaces)
        Task {
            let success = await vm.addICS(feedURL: feedValue, label: labelValue)
            isConnectingICS = false
            if success {
                dismiss()
            } else {
                icsError = vm.error
                // Snapshot only — the secret feed URL itself never reaches
                // the assistant, just the fact that the field is filled.
                if showAssistant, let err = icsError, let chatVM = setupChatVM {
                    chatVM.sendConnectionError(err, snapshot: formSnapshot())
                }
            }
        }
    }
}

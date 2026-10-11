import SwiftUI
import WatchtowerSync

/// Settings (pushed from Now's gear): Your Mac, read-only accounts, the Workbench
/// requests to the Mac, notifications, the parked offline chat, and Unlink
/// this Mac.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(LinkingViewModel.self) private var linking
    @State private var model = SettingsViewModel()
    @State private var confirmingUnlink = false

    var body: some View {
        Form {
            yourMacSection
            accountsSection
            workbenchSection
            notificationsSection
            Section {
                Text("Chat without the Mac — later")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Chat")
            }
            .disabled(true)
            unlinkSection
        }
        .navigationTitle("Settings")
        .task(id: env.linkedDevice?.deviceID) {
            model.start(store: env.store, deviceID: env.linkedDevice?.deviceID)
        }
    }

    // MARK: - Your Mac

    private var yourMacSection: some View {
        Section("Your Mac") {
            // The status turns offline by the clock alone, so re-evaluate it
            // periodically, not only on replica writes. One row: the Form
            // lays a TimelineView's views out in one cell.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let row = MacStatusRow(status: MacStatus(heartbeat: model.snapshot.heartbeat, now: context.date), now: context.date)
                LabeledContent {
                    HStack(spacing: Spacing.compact) {
                        Circle().fill(row.tone.color).frame(width: 8, height: 8)
                        Text(row.value)
                    }
                } label: {
                    Text(row.label)
                }
            }
            LabeledContent("Last sync") {
                if let last = env.lastSyncAt {
                    Text(last, style: .relative)
                } else {
                    Text("Never")
                }
            }
            LabeledContent("Queued", value: "\(model.snapshot.queuedCount)")
            if env.transportKind == .inMemoryDemo {
                LabeledContent("Sync", value: "Demo")
            }
        }
    }

    // MARK: - Accounts (read-only)

    @ViewBuilder private var accountsSection: some View {
        let accounts = model.snapshot.heartbeat?.accounts ?? []
        if !accounts.isEmpty {
            Section {
                ForEach(Array(accounts.enumerated()), id: \.offset) { _, account in
                    LabeledContent {
                        Text(account.status)
                    } label: {
                        Label(account.label, systemImage: Self.symbol(for: account.kind))
                    }
                }
            } header: {
                Text("Accounts")
            } footer: {
                Text("Accounts are managed on your Mac.")
            }
        }
    }

    static func symbol(for kind: HeartbeatAccount.Kind) -> String {
        switch kind {
        case .slack: "number"
        case .google: "envelope"
        case .jira: "checklist"
        default: "person.crop.circle"
        }
    }

    // MARK: - Workbench

    private var workbenchSection: some View {
        let settings = env.deviceSettings
        return Section {
            Toggle("Type into sessions from this phone", isOn: Binding(
                get: { settings.typingRequested },
                set: { value in Task { await settings.setTypingRequested(value) } }
            ))
            Toggle("Start sessions from this phone", isOn: Binding(
                get: { settings.startSessions },
                set: { value in Task { await settings.setStartSessions(value) } }
            ))
        } header: {
            Text("Workbench")
        } footer: {
            workbenchFooter(settings)
        }
    }

    @ViewBuilder
    private func workbenchFooter(_ settings: DeviceSettings) -> some View {
        if let error = settings.lastError {
            Text(error).foregroundStyle(.red)
        } else if settings.typingRequested {
            Text(Self.typingCaption(grant: model.snapshot.grant))
        }
    }

    /// The typing request's answer from the Mac (spec §4.13).
    static func typingCaption(grant: DeviceGrant?) -> String {
        grant?.typingAllowed == true
            ? "Allowed"
            : "Waiting for your Mac to confirm"
    }

    // MARK: - Unlink

    /// A live link only: the demo has no link to end.
    @ViewBuilder private var unlinkSection: some View {
        if env.transportKind == .cloudKit, linking.link != nil {
            Section {
                Button("Unlink this Mac", role: .destructive) {
                    confirmingUnlink = true
                }
                .frame(minHeight: 44)
                .disabled(linking.isBusy)
                .confirmationDialog("Unlink this Mac?", isPresented: $confirmingUnlink, titleVisibility: .visible) {
                    Button("Unlink", role: .destructive) {
                        Task { await linking.unlink() }
                    }
                } message: {
                    Text("This phone forgets the Mac's data. Changes still waiting for the Mac are not sent.")
                }
            } footer: {
                Text("To use Watchtower here again, scan a new code on the Mac.")
            }
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        @Bindable var settings = env.deviceSettings
        return Section("Notifications") {
            Toggle("New asks", isOn: $settings.newAskAlerts)
        }
    }
}

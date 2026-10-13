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
                MacStatusRowView(row: row)
                // Nothing at all while every observation is healthy.
                ForEach(model.diagnostics(now: context.date)) { row in
                    Text(row.text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            // Its own TimelineView: a Form lays one TimelineView's views out
            // in one cell, and "3 min. ago" moves with the clock alone.
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                LabeledContent("Last sync", value: LastSyncText.string(env.lastSyncAt))
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
                        AccountStatusLabel(style: AccountStatusStyle(status: account.status))
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
    static func offersUnlink(transportKind: TransportKind, link: LinkRecord?) -> Bool {
        transportKind == .cloudKit && link != nil
    }

    @ViewBuilder private var unlinkSection: some View {
        if Self.offersUnlink(transportKind: env.transportKind, link: linking.link) {
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

/// SET3's mark and text, in the style's tones.
private struct AccountStatusLabel: View {
    let style: AccountStatusStyle

    var body: some View {
        HStack(spacing: Spacing.compact) {
            switch style.mark {
            case .dot:
                Circle().fill(style.tone.color).frame(width: 8, height: 8)
            case let .symbol(name):
                Image(systemName: name).foregroundStyle(style.tone.color)
            case .textOnly:
                EmptyView()
            }
            Text(style.text).foregroundStyle(style.textTone.color)
        }
    }
}

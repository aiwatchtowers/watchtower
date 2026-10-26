import SwiftUI
import WatchtowerSync

/// Settings (pushed from Now's gear): This Mac and Macs, read-only accounts, the Workbench
/// requests to the Mac, notifications, the parked offline chat, and Unlink
/// this Mac.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(LinkingViewModel.self) private var linking
    @State private var model = SettingsViewModel()
    @State private var confirmingUnlink = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                yourMacSection
                accountsSection
                workbenchSection
                notificationsSection
                if let battery = model.battery {
                    BatterySection(report: battery)
                }
                SettingsCard(title: "Chat") {
                    SettingsRow(title: "Chat without the Mac — later") { EmptyView() }
                }
                .disabled(true)
                unlinkSection
            }
            .padding(.horizontal, Spacing.large)
            .padding(.bottom, Spacing.wide)
        }
        .navigationTitle("Settings")
        // A new device id or a new environment (the link flow swaps it)
        // restarts the observation.
        .task(id: ObservationKey(store: ObjectIdentifier(env.store), deviceID: env.linkedDevice?.deviceID)) {
            model.start(store: env.store, deviceID: env.linkedDevice?.deviceID)
        }
        // The counters change on every fetch; re-read them while Settings
        // is on screen.
        .task {
            while !Task.isCancelled {
                model.refreshBattery()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    // MARK: - Your Mac

    private var yourMacSection: some View {
        SettingsCard(title: "This Mac") {
            // The status turns offline by the clock alone, so re-evaluate it
            // periodically, not only on replica writes.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let row = MacStatusRow(status: MacStatus(heartbeat: model.snapshot.heartbeat, now: context.date), now: context.date)
                VStack(alignment: .leading, spacing: 0) {
                    MacStatusRowView(row: row)
                    // Nothing at all while every observation is healthy.
                    ForEach(model.diagnostics(now: context.date)) { row in
                        note(row.text)
                    }
                }
            }
            CardRowDivider()
            // Its own TimelineView: "3 min. ago" moves with the clock alone.
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                SettingsRow(title: "Last sync") { Text(LastSyncText.string(env.lastSyncAt)) }
            }
            CardRowDivider()
            SettingsRow(title: "Queued") { Text("\(model.snapshot.queuedCount)") }
            if env.transportKind == .inMemoryDemo {
                CardRowDivider()
                SettingsRow(title: "Sync") { Text("Demo") }
            }
            if env.transportKind == .cloudKit || !linking.links.isEmpty {
                CardRowDivider()
                NavigationLink {
                    MacsView()
                } label: {
                    SettingsRow(title: "Macs") {
                        HStack(spacing: Spacing.regular) {
                            Text("\(linking.links.count + linking.unreadableHubIDs.count)")
                            Image(systemName: "chevron.right").font(TypeScale.badge)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            if model.waitingForKeys {
                CardRowDivider()
                note(SettingsViewModel.waitingForKeysNotice)
            }
            if let notice = model.formatNotice {
                CardRowDivider()
                note(notice, tone: PhoneTone.red.color)
            }
        }
        .onChange(of: env.lastSyncAt) { model.refreshFormatNotice() }
    }

    /// A line of explanation inside a card.
    private func note(_ text: String, tone: Color = Color.secondary) -> some View {
        Text(text)
            .font(TypeScale.meta)
            .foregroundStyle(tone)
            .padding(.vertical, Spacing.regular)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Accounts (read-only)

    @ViewBuilder private var accountsSection: some View {
        let accounts = model.snapshot.heartbeat?.accounts ?? []
        if !accounts.isEmpty {
            SettingsCard(title: "Accounts", footer: "Accounts are managed on your Mac.") {
                ForEach(Array(accounts.enumerated()), id: \.offset) { index, account in
                    if index > 0 { CardRowDivider() }
                    HStack(spacing: Spacing.medium) {
                        Label(account.label, systemImage: Self.symbol(for: account.kind))
                            .font(TypeScale.rowTitle)
                        Spacer(minLength: Spacing.medium)
                        AccountStatusLabel(style: AccountStatusStyle(status: account.status))
                            .font(.subheadline)
                    }
                    .frame(minHeight: PhoneMetrics.minTouch)
                    .accessibilityElement(children: .combine)
                }
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
        let typing = Binding(
            get: { settings.typingRequested },
            set: { value in Task { await settings.setTypingRequested(value) } }
        )
        let start = Binding(
            get: { settings.startSessions },
            set: { value in Task { await settings.setStartSessions(value) } }
        )
        let permissions = Binding(
            get: { settings.permissionsRequested },
            set: { value in Task { await settings.setPermissionsRequested(value) } }
        )
        return VStack(alignment: .leading, spacing: 0) {
            SettingsCard(title: "Workbench", footer: workbenchFooter(settings)) {
                switchRow("Type into sessions from this phone", isOn: typing)
                CardRowDivider()
                switchRow("Start sessions from this phone", isOn: start)
                CardRowDivider()
                switchRow("Answer permission prompts from this phone", isOn: permissions)
            }
            if let error = settings.lastError {
                Text(error)
                    .font(TypeScale.meta)
                    .foregroundStyle(PhoneTone.red.color)
                    .padding(.horizontal, Spacing.small)
                    .padding(.top, Spacing.compact)
            }
        }
    }

    private func switchRow(_ title: String, isOn: Binding<Bool>) -> some View {
        SettingsRow(title: title) {
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(SmallSwitchStyle())
        }
    }

    /// The Mac's answer to each request made; an error is drawn apart, in red.
    private func workbenchFooter(_ settings: DeviceSettings) -> String? {
        guard settings.lastError == nil else { return nil }
        let lines = [
            settings.typingRequested ? "Typing: \(Self.typingCaption(grant: model.snapshot.grant))" : nil,
            settings.startSessions ? "Starting sessions: \(Self.startSessionsCaption(grant: model.snapshot.grant))" : nil,
            settings.permissionsRequested ? "Permission prompts: \(Self.permissionsCaption(grant: model.snapshot.grant))" : nil
        ].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The typing request's answer from the Mac (spec §4.13).
    static func typingCaption(grant: DeviceGrant?) -> String {
        grant?.typingAllowed == true
            ? "Allowed"
            : "Waiting for your Mac to confirm"
    }

    /// Whether the Mac lets this phone start sessions (#565): the owner
    /// allows it on the Mac, after typing.
    static func startSessionsCaption(grant: DeviceGrant?) -> String {
        grant?.mayStartSessions == true
            ? "Allowed"
            : "Allow it on your Mac: Watchtower → Settings → Mobile, after typing"
    }

    /// The permission-prompt request's answer from the Mac (#517): its own
    /// grant, never the typing one.
    static func permissionsCaption(grant: DeviceGrant?) -> String {
        grant?.permissionsAllowed == true
            ? "Allowed"
            : "Waiting for your Mac to confirm"
    }

    // MARK: - Unlink

    /// A live link only: the demo has no link to end.
    static func offersUnlink(transportKind: TransportKind, link: LinkRecord?) -> Bool {
        transportKind == .cloudKit && link != nil
    }

    /// The saved link of the hub on screen.
    private var activeLink: LinkRecord? {
        linking.links.first { $0.hubID == env.activeHubID }?.link
    }

    /// The Mac on screen as Settings → Macs lists it.
    private var activeItem: HubListItem? {
        env.hubListItems(linking.links, now: Date()).first(where: \.isActive)
    }

    /// The Mac on screen's one destructive action, as Settings → Macs offers
    /// it (`MacsModel.action`): Forget, with its copy, for a Mac that
    /// removed this phone or is long offline, else Unlink.
    static func removalAsk(for item: HubListItem?) -> MacsModel.Ask? {
        item.map { MacsModel.Ask(action: MacsModel.action(for: $0), item: $0) }
    }

    @ViewBuilder private var unlinkSection: some View {
        if let link = activeLink, Self.offersUnlink(transportKind: env.transportKind, link: link),
           let ask = Self.removalAsk(for: activeItem) {
            VStack(alignment: .leading, spacing: 0) {
                Button(role: .destructive) {
                    confirmingUnlink = true
                } label: {
                    Text("\(ask.button) \(ask.name)")
                        .font(TypeScale.rowEmphasis)
                        .foregroundStyle(PhoneTone.red.color)
                        .frame(maxWidth: .infinity, minHeight: PhoneMetrics.minTouch)
                        .card(.plain, padding: EdgeInsets())
                }
                .buttonStyle(.plain)
                .disabled(linking.isBusy)
                .padding(.top, Spacing.large)
                .confirmationDialog(ask.title, isPresented: $confirmingUnlink, titleVisibility: .visible) {
                    Button(ask.button, role: .destructive) {
                        Task {
                            switch ask.action {
                            case .unlink: await linking.unlink(link.hubID)
                            case .forget: await linking.forget(link.hubID)
                            }
                        }
                    }
                } message: {
                    Text(ask.message)
                }
                Text("To use Watchtower here again, scan a new code on the Mac.")
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.small)
                    .padding(.top, Spacing.compact)
            }
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        let alerts = Binding(
            get: { env.deviceSettings.workAlerts },
            set: { value in Task { await env.setWorkAlerts(value) } }
        )
        return SettingsCard(title: "Notifications", footer: WorkAlertsCopy.footer(anyShared: env.anyHubShared)) {
            switchRow(WorkAlertsCopy.title, isOn: alerts)
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
                Circle().fill(style.tone.color).frame(width: PhoneMetrics.macDot, height: PhoneMetrics.macDot)
            case let .symbol(name):
                Image(systemName: name).foregroundStyle(style.tone.color)
            case .textOnly:
                EmptyView()
            }
            Text(style.text).foregroundStyle(style.textTone.color)
        }
    }
}

/// What Settings' observation follows.
private struct ObservationKey: Equatable {
    let store: ObjectIdentifier
    let deviceID: String?
}

import SwiftUI
import WatchtowerSync

/// Settings → Mobile tab: builds the model over `AppState` once, on first
/// appearance.
struct MobileSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var model: MobileSettingsViewModel?

    var body: some View {
        Group {
            if let model {
                MobileSettingsView(model: model)
            } else {
                Color.clear
            }
        }
        .onAppear {
            if model == nil { model = MobileSettingsViewModel(host: appState) }
        }
    }
}

/// Settings → Mobile (mobile POC spec §2.3, §8 I-1, §9, §10): the opt-in
/// toggle, the hub status, Use Watchtower on iPhone (the QR sheet) and the
/// linked phones.
struct MobileSettingsView: View {
    let model: MobileSettingsViewModel

    var body: some View {
        Form {
            toggleSection
            if model.isOn {
                hubSection
                phonesSection
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal)
        .padding(.top, 4)
        .onAppear { model.appeared() }
        .onDisappear { Task { await model.disappeared() } }
        .sheet(item: Binding(
            get: { model.linkSheet },
            set: { if $0 == nil { Task { await model.linkSheetDismissed() } } }
        )) { sheet in
            MobileLinkSheet(model: sheet) { Task { await model.linkSheetDismissed() } }
        }
        .confirmationDialog(
            "Allow \(model.pendingAllow?.name ?? "this phone") to type into your sessions?",
            isPresented: Binding(
                get: { model.pendingAllow != nil },
                set: { if !$0 { model.pendingAllow = nil } }
            )
        ) {
            Button("Allow") { model.confirmAllow() }
            Button("Cancel", role: .cancel) { model.pendingAllow = nil }
        } message: {
            Text("The phone can then send text to sessions running on this Mac. Revoke turns it off again.")
        }
    }

    private var toggleSection: some View {
        Section {
            Toggle("Use Watchtower on iPhone", isOn: Binding(
                get: { model.isOn },
                set: { enabled in Task { await model.setEnabled(enabled) } }
            ))
            .disabled(model.toggleDisabled)
            if !model.entitlementPresent {
                Text(MobileSettingsViewModel.needsSignedBuild)
                    .foregroundStyle(.secondary)
            }
            if model.showsCorpNotice {
                Text(MobileSettingsViewModel.corpNotice)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("This Mac becomes the hub the iPhone app syncs with, through your own iCloud.")
        }
    }

    private var hubSection: some View {
        Section("Hub") {
            if let error = model.hubInitError {
                Text("Mobile couldn't start: \(error)")
                    .foregroundStyle(.red)
            }
            if let message = model.accountMessage {
                Text(message)
                    .foregroundStyle(.orange)
            }
            if let line = model.statusLine {
                Text(line)
            }
            if model.offersTakeOver {
                Button("Take over") { Task { await model.takeOver() } }
            }
            if model.hub?.status == .running {
                Text(lastPublishText)
                    .foregroundStyle(.secondary)
                Text("Backlog: \(model.relayBacklog)")
                    .foregroundStyle(.secondary)
            }
            if model.showsSlowingLine {
                Text(MobileSettingsViewModel.slowingLine)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var lastPublishText: String {
        guard let at = model.lastPublishAt else { return "Last publish: not yet" }
        return "Last publish: \(at.formatted(date: .omitted, time: .standard))"
    }

    private var phonesSection: some View {
        Section("Phones") {
            if model.canShowCode {
                Button("Use Watchtower on iPhone") { model.showCode() }
            }
            if model.devices.isEmpty {
                Text("No phones linked yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.devices, id: \.deviceID) { device in
                MobilePhoneRow(
                    device: device,
                    onAllow: { model.requestAllow(device) },
                    onRevoke: { model.revoke(device) },
                    onRemove: { Task { await model.remove(device) } }
                )
            }
            if let notice = model.notice {
                Text(notice)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One linked phone: name, Apple ID scope, link date and typing state, with
/// Allow… / Revoke and Remove.
private struct MobilePhoneRow: View {
    let device: HubSyncState.LinkedDevice
    let onAllow: () -> Void
    let onRevoke: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                HStack(spacing: 6) {
                    Text(MobileSettingsViewModel.scopeLabel(device.scope))
                    Text("Linked \(device.linkedAt.formatted(date: .abbreviated, time: .shortened))")
                    Text(device.typingAllowed ? "Typing allowed" : "Typing off")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if device.typingAllowed {
                Button("Revoke", action: onRevoke)
            } else {
                Button("Allow…", action: onAllow)
            }
            Button("Remove", role: .destructive, action: onRemove)
        }
    }
}

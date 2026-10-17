import AppKit
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
    /// Whether the Settings window is on screen; the polling runs only then.
    @State private var windowVisible = true

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
        .background(WindowVisibilityReader(isVisible: $windowVisible))
        .task(id: windowVisible) { await model.windowVisibility(windowVisible) }
        .onDisappear { Task { await model.disappeared() } }
        .sheet(item: Binding(
            get: { model.linkSheet },
            set: { if $0 == nil { Task { await model.linkSheetDismissed() } } }
        )) { sheet in
            MobileLinkSheet(model: sheet) { Task { await model.linkSheetDismissed() } }
        }
        .confirmationDialog(
            MobileSettingsViewModel.allowQuestion(name: model.pendingAllow?.name ?? "this phone"),
            isPresented: Binding(
                get: { model.pendingAllow != nil },
                set: { if !$0 { model.pendingAllow = nil } }
            )
        ) {
            Button("Allow") { model.confirmAllow() }
            Button("Cancel", role: .cancel) { model.pendingAllow = nil }
        } message: {
            Text(MobileSettingsViewModel.allowMessage(model.pendingAllow))
        }
        .confirmationDialog(
            MobileSettingsViewModel.startSessionsQuestion(name: model.pendingStartSessionsAllow?.name ?? "this phone"),
            isPresented: Binding(
                get: { model.pendingStartSessionsAllow != nil },
                set: { if !$0 { model.pendingStartSessionsAllow = nil } }
            )
        ) {
            Button("Allow") { model.confirmStartSessionsAllow() }
            Button("Cancel", role: .cancel) { model.pendingStartSessionsAllow = nil }
        } message: {
            Text("The phone can then start a session on a board target, and the agent reads that target's text. "
                + "Revoke turns it off again.")
        }
        .confirmationDialog(
            MobileSettingsViewModel.permissionsQuestion(name: model.pendingPermissionsAllow?.name ?? "this phone"),
            isPresented: Binding(
                get: { model.pendingPermissionsAllow != nil },
                set: { if !$0 { model.pendingPermissionsAllow = nil } }
            )
        ) {
            Button("Allow") { model.confirmPermissionsAllow() }
            Button("Cancel", role: .cancel) { model.pendingPermissionsAllow = nil }
        } message: {
            Text("The phone can then allow or deny a Claude Code permission prompt, one call at a time. "
                + "Revoke turns it off again.")
        }
    }

    private var toggleSection: some View {
        Section {
            Toggle("Sync with iPhone", isOn: Binding(
                get: { model.isOn },
                set: { enabled in Task { await model.setEnabled(enabled) } }
            ))
            .disabled(model.toggleDisabled)
            if !model.entitlementPresent {
                Text(MobileSettingsViewModel.needsSignedBuild)
                    .foregroundStyle(.secondary)
            }
            if let problem = model.hubOffLine {
                Text(problem)
                    .foregroundStyle(.orange)
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
                    onAllowStartSessions: { model.requestStartSessionsAllow(device) },
                    onRevokeStartSessions: { model.revokeStartSessions(device) },
                    onAllowPermissions: { model.requestPermissionsAllow(device) },
                    onRevokePermissions: { model.revokePermissions(device) },
                    onRemove: { model.requestRemove(device) }
                )
            }
            if let notice = model.notice {
                Text(notice)
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(
            MobileSettingsViewModel.removeQuestion(name: model.removeSubject?.name ?? "this phone"),
            isPresented: Binding(
                get: { model.pendingRemove != nil },
                set: { if !$0 { model.pendingRemove = nil } }
            )
        ) {
            Button("Remove", role: .destructive) { Task { await model.confirmRemove() } }
            Button("Cancel", role: .cancel) { model.pendingRemove = nil }
        } message: {
            Text(MobileSettingsViewModel.removeConsequence(model.removeSubject?.scope ?? .shared))
        }
    }
}

/// One linked phone: name, Apple ID scope and link date, then one line per
/// grant (typing, starting sessions, answering permission prompts) with its
/// own Allow… / Revoke, and Remove. Starting sessions can be allowed only
/// while typing is (#565).
private struct MobilePhoneRow: View {
    let device: HubSyncState.LinkedDevice
    let onAllow: () -> Void
    let onRevoke: () -> Void
    let onAllowStartSessions: () -> Void
    let onRevokeStartSessions: () -> Void
    let onAllowPermissions: () -> Void
    let onRevokePermissions: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                HStack(spacing: 6) {
                    Text(MobileSettingsViewModel.scopeLabel(device.scope))
                    Text("Linked \(device.linkedAt.formatted(date: .abbreviated, time: .shortened))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                grantLine(
                    MobileSettingsViewModel.typingLabel(device), requested: device.typingRequested,
                    allowed: device.typingAllowed, onAllow: onAllow, onRevoke: onRevoke
                )
                grantLine(
                    MobileSettingsViewModel.startSessionsLabel(device), requested: false,
                    // Allow… waits for typing; a Revoke always works.
                    allowed: device.startSessionsGranted, enabled: device.typingAllowed || device.startSessionsGranted,
                    onAllow: onAllowStartSessions, onRevoke: onRevokeStartSessions
                )
                grantLine(
                    MobileSettingsViewModel.permissionsLabel(device), requested: device.permissionsRequested,
                    allowed: device.permissionsAllowed, onAllow: onAllowPermissions, onRevoke: onRevokePermissions
                )
            }
            Spacer()
            Button("Remove…", role: .destructive, action: onRemove)
        }
    }

    /// A grant's state (a pending request in the accent colour) and its
    /// Allow… or Revoke.
    private func grantLine(
        _ label: String,
        requested: Bool,
        allowed: Bool,
        enabled: Bool = true,
        onAllow: @escaping () -> Void,
        onRevoke: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(requested && !allowed ? Color.accentColor : Color.secondary)
            if allowed {
                Button("Revoke", action: onRevoke)
            } else {
                Button("Allow…", action: onAllow)
            }
        }
        .disabled(!enabled)
        .controlSize(.small)
    }
}

/// Reports whether the hosting window is on screen (shown and not fully
/// covered): a closed Settings window is ordered out, which SwiftUI does
/// not always answer with `onDisappear`.
private struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> WindowVisibilityView {
        let view = WindowVisibilityView()
        view.onChange = { visible in
            // Off the view update in progress.
            DispatchQueue.main.async { if isVisible != visible { isVisible = visible } }
        }
        return view
    }

    func updateNSView(_ nsView: WindowVisibilityView, context: Context) {}

    static func dismantleNSView(_ nsView: WindowVisibilityView, coordinator: ()) {
        nsView.stopObserving()
    }
}

private final class WindowVisibilityView: NSView {
    var onChange: ((Bool) -> Void)?
    /// Written on the main actor only; read by `deinit` after every other
    /// reference is gone.
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func stopObserving() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Leaving the window (the view going away) ends the observation.
        stopObserving()
        guard let window else {
            onChange?(false)
            return
        }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let window else { return }
                self?.onChange?(window.occlusionState.contains(.visible))
            }
        }
        onChange?(window.occlusionState.contains(.visible))
    }
}

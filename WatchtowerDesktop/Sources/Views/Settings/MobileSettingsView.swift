import AppKit
import SwiftUI
import WatchtowerCore

/// Settings → Mobile tab: builds the model over the app once, on first
/// appearance, and reads the hub again when `HubCenter` says it changed.
struct MobileSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var model: MobileSettingsModel?

    var body: some View {
        Group {
            if let model {
                MobileSettingsView(model: model)
            } else {
                Color.clear
            }
        }
        .onAppear {
            if model == nil { model = appState.makeMobileSettingsModel() }
        }
        .onChange(of: appState.hubCenter?.status) { Task { await model?.load() } }
        .onChange(of: appState.hubCenter?.linksChanged) { Task { await model?.load() } }
    }
}

/// Settings → Mobile over `watchtower hub …` (go hub plan 3 Task 23,
/// mockups §1–§9): every line comes from `MobileSettingsModel`.
struct MobileSettingsView: View {
    typealias Copy = MobileSettingsModel
    let model: MobileSettingsModel
    /// Whether the Settings window is on screen; the reads repeat only then.
    @State private var windowVisible = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.large) {
                content
                if let notice = model.notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Spacing.large)
            .padding(.vertical, Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(WindowVisibilityReader(isVisible: $windowVisible))
        .task(id: windowVisible) { await model.windowVisibility(windowVisible) }
        .onDisappear { model.disappeared() }
        .sheet(item: Binding(get: { model.pairing }, set: { if $0 == nil { model.pairingDismissed() } })) { sheet in
            MobilePairingSheet(model: sheet) { model.pairingDismissed() }
                .task { await sheet.start() }
        }
        .modifier(MobileSettingsDialogs(model: model))
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            SettingsSection(title: Copy.sectionTitle) {
                HStack(spacing: Spacing.regular) {
                    ProgressView().controlSize(.small)
                    Text(Copy.loadingText).foregroundStyle(.secondary)
                }
            }
        case .error(let message):
            SettingsSection(title: Copy.sectionTitle) {
                SettingRow(title: message) {
                    Button(Copy.retryTitle) { Task { await model.load() } }.buttonStyle(.kitSecondary)
                }
            }
        case .adoption(let adoption):
            MobileAdoptionSection(adoption: adoption) { Task { await model.retryAdoption() } }
        case .off(let reason):
            MobileOffSection(model: model, copy: Copy.offCopy(reason))
        case .noPhones:
            MobileHubSection(model: model)
            MobilePhonesSection(model: model, rows: [])
            MobileRecordingsSection(model: model)
        case .phones(let rows):
            MobileHubSection(model: model)
            MobilePhonesSection(model: model, rows: rows)
            MobileRecordingsSection(model: model)
        }
    }
}

/// The hand-over of Mobile to the new version (Task 22's state): a spinner
/// while it runs, the reason and Retry when it failed.
private struct MobileAdoptionSection: View {
    let adoption: HubAdoptionState
    let onRetry: () -> Void

    var body: some View {
        SettingsSection(title: MobileSettingsModel.sectionTitle) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                if case .inProgress = adoption { ProgressView().controlSize(.small) }
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(adoption.title)
                        .foregroundStyle(adoption.retryTitle == nil ? Color.primary : Tone.error)
                    if let detail = adoption.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: Spacing.medium)
                if let retry = adoption.retryTitle {
                    Button(retry, action: onRetry).buttonStyle(.kitPrimary)
                }
            }
        }
    }
}

/// The hub is off: the reason, the owner's switch unless a policy decides.
private struct MobileOffSection: View {
    let model: MobileSettingsModel
    let copy: MobileSettingsModel.OffCopy

    var body: some View {
        SettingsSection(title: MobileSettingsModel.sectionTitle) {
            SettingRow(title: copy.title, caption: copy.detail) {
                if copy.managed {
                    ManagedByOrganizationBadge()
                } else if copy.showsToggle {
                    MobileSyncToggle(model: model)
                }
            }
            MobileCorpNotice(model: model)
        }
    }
}

/// The owner's Mobile sync switch, busy while `hub enable|disable` runs.
private struct MobileSyncToggle: View {
    let model: MobileSettingsModel

    var body: some View {
        HStack(spacing: Spacing.regular) {
            if model.busy.contains(.toggle) { ProgressView().controlSize(.small) }
            Toggle(MobileSettingsModel.toggleTitle, isOn: Binding(
                get: { model.isOn },
                set: { on in Task { await model.setEnabled(on) } }
            ))
            .labelsHidden()
            .disabled(model.busy.contains(.toggle))
        }
    }
}

private struct MobileCorpNotice: View {
    let model: MobileSettingsModel

    var body: some View {
        if model.showsCorpNotice {
            Text(MobileSettingsModel.corpNotice).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The running hub: the switch, the Mac name, recordings, the transport.
private struct MobileHubSection: View {
    typealias Copy = MobileSettingsModel
    let model: MobileSettingsModel

    var body: some View {
        SettingsSection(title: Copy.sectionTitle) {
            SettingRow(title: Copy.toggleTitle, caption: model.hubLine ?? Copy.toggleOnCaption) {
                MobileSyncToggle(model: model)
            }
            MobileCorpNotice(model: model)
            SettingRow(title: Copy.macNameTitle, caption: Copy.macNameCaption) {
                HStack(spacing: Spacing.regular) {
                    if model.busy.contains(.name) { ProgressView().controlSize(.small) }
                    Button(model.macName) { model.renaming = model.macName }
                        .buttonStyle(.kitSecondary)
                        .disabled(model.busy.contains(.name))
                }
            }
            recordingsRow
            if let transport = model.hubTransport {
                SettingRow(title: Copy.transportTitle, caption: model.hubSwitchedLine) {
                    Chip(text: Copy.transportLabel(transport), color: MobileTransportTone.color(transport))
                }
            }
            if model.showsBridgeUnavailable {
                Text(Copy.bridgeUnavailableLine).font(.caption).foregroundStyle(Tone.warning)
            }
            SettingRow(title: Copy.keepAwakeTitle, caption: Copy.keepAwakeCaption) {
                Toggle(Copy.keepAwakeTitle, isOn: Binding(get: { model.keepAwake }, set: { model.setKeepAwake($0) }))
                    .labelsHidden()
            }
        }
    }

    private var recordingsRow: some View {
        let busy = model.busy.contains(.recordings)
        return VStack(alignment: .leading, spacing: Spacing.tight) {
            SettingRow(
                title: Copy.recordingsTitle,
                caption: busy ? (model.recordingsOn ? Copy.turningOff : Copy.turningOn) : Copy.recordingsCaption
            ) {
                HStack(spacing: Spacing.regular) {
                    if busy { ProgressView().controlSize(.small) }
                    Toggle(Copy.recordingsTitle, isOn: Binding(
                        get: { model.recordingsOn },
                        set: { on in Task { await model.setRecordings(on) } }
                    ))
                    .labelsHidden()
                    .disabled(busy || (!model.recordingsAvailable && !model.recordingsOn))
                }
            }
            if let error = model.recordingsError {
                Text(error).font(.caption).foregroundStyle(Tone.error)
            }
        }
    }
}

/// A transport's pill colour.
enum MobileTransportTone {
    static func color(_ transport: String) -> Color {
        switch MobileSettingsModel.TransportKind(transport) {
        case .iCloud: Tone.status(MobileSettingsModel.iCloudStatusColor)
        case .relay: Tone.success
        case .pending: Tone.warning
        }
    }
}

/// The linked phones, or "No phones linked", and Link a phone….
private struct MobilePhonesSection: View {
    typealias Copy = MobileSettingsModel
    let model: MobileSettingsModel
    let rows: [MobileSettingsModel.PhoneRow]

    var body: some View {
        SettingsSection(title: Copy.phonesTitle) {
            if rows.isEmpty {
                SettingRow(title: Copy.emptyText, caption: Copy.emptyDetail) { EmptyView() }
            }
            ForEach(rows) { row in
                MobilePhoneRow(model: model, row: row)
            }
        }
        Button(Copy.linkTitle) { model.linkPhone() }
            .buttonStyle(.kitPrimary)
            .disabled(!model.canLink)
    }
}

/// One linked phone: name, link date, transport and who switched it, one
/// line per grant with its own Allow… / Revoke, and Remove… on hover.
private struct MobilePhoneRow: View {
    typealias Copy = MobileSettingsModel
    let model: MobileSettingsModel
    let row: MobileSettingsModel.PhoneRow
    @State private var hovered = false

    var body: some View {
        let busy = model.busy.contains(.phone(row.id))
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(row.name)
                    Text(row.detailLine).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: Spacing.medium)
                if busy { ProgressView().controlSize(.small) }
                Chip(text: row.transportLabel, color: MobileTransportTone.color(row.transport))
                Button(Copy.removeTitle) { model.requestRemove(row) }
                    .buttonStyle(.kitQuiet)
                    .foregroundStyle(Tone.error)
                    .opacity(hovered ? 1 : 0)
            }
            Grid(alignment: .leading, horizontalSpacing: Spacing.medium, verticalSpacing: Spacing.small) {
                grantRow(Copy.typingLabel(row), requested: row.typingRequested, allowed: row.typing,
                         onAllow: { model.requestAllow(row) }, onRevoke: { Task { await model.allow(row.id, Copy.typingGrant, false) } })
                grantRow(Copy.startSessionsLabel(row), requested: false, allowed: row.startSessionsGranted,
                         enabled: row.typing || row.startSessionsGranted,
                         onAllow: { model.requestStartSessionsAllow(row) },
                         onRevoke: { Task { await model.allow(row.id, Copy.startSessionsGrant, false) } })
                grantRow(Copy.permissionsLabel(row), requested: row.permissionsRequested, allowed: row.permissions,
                         onAllow: { model.requestPermissionsAllow(row) },
                         onRevoke: { Task { await model.allow(row.id, Copy.permissionsGrant, false) } })
            }
            .disabled(busy)
        }
        .kitRow(isSelected: false)
        .onHover { hovered = $0 }
    }

    private func grantRow(
        _ label: String,
        requested: Bool,
        allowed: Bool,
        enabled: Bool = true,
        onAllow: @escaping () -> Void,
        onRevoke: @escaping () -> Void
    ) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(requested && !allowed ? Color.accentColor : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if allowed {
                    Button(Copy.revokeTitle, action: onRevoke)
                } else {
                    Button(Copy.allowTitle, action: onAllow)
                }
            }
            .buttonStyle(.kitQuiet)
            .gridColumnAlignment(.trailing)
            .disabled(!enabled)
        }
        .controlSize(.small)
    }
}

/// The recordings the update kept (Show in Finder, removal date) and the
/// failed phone recordings (Retry, Discard…); absent when there are none.
private struct MobileRecordingsSection: View {
    typealias Copy = MobileSettingsModel
    let model: MobileSettingsModel

    var body: some View {
        if model.keptRecordings != nil || !model.failedRecordings.isEmpty {
            SettingsSection(title: Copy.recordingsSectionTitle) {
                if let kept = model.keptRecordings {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.medium) {
                        VStack(alignment: .leading, spacing: Spacing.tight) {
                            Text(Copy.keptLine(kept)).foregroundStyle(Tone.warning)
                            Text(Copy.keptRemovalLine(kept)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: Spacing.medium)
                        Button(Copy.showInFinderTitle) { model.showKeptRecordingsInFinder() }.buttonStyle(.kitSecondary)
                    }
                }
                ForEach(model.failedRecordings) { recording in
                    failedRow(recording)
                }
            }
        }
    }

    private func failedRow(_ recording: MobileSettingsModel.FailedRecording) -> some View {
        let busy = model.busy.contains(.recording(recording.id))
        return HStack(alignment: .firstTextBaseline, spacing: Spacing.medium) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(recording.line)
                Text(Copy.failedRecordingCaption).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.medium)
            if busy { ProgressView().controlSize(.small) }
            if recording.retryable {
                Button(Copy.retryTitle) { Task { await model.retryRecording(recording.id) } }.buttonStyle(.kitSecondary)
            }
            Button(Copy.discardTitle) { model.requestDiscard(recording) }
                .buttonStyle(.kitQuiet)
                .foregroundStyle(Tone.error)
        }
        .disabled(busy)
    }
}

/// The confirmations (Allow… for each grant, Remove…, Discard…) and the rename field.
private struct MobileSettingsDialogs: ViewModifier {
    typealias Copy = MobileSettingsModel
    let model: MobileSettingsModel

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                Copy.allowQuestion(name: model.pendingAllow?.name ?? Copy.thisPhone),
                isPresented: Binding(get: { model.pendingAllow != nil }, set: { if !$0 { model.pendingAllow = nil } })
            ) {
                Button(Copy.allowConfirmTitle) { Task { await model.confirmAllow() } }
                Button(Copy.cancelTitle, role: .cancel) { model.pendingAllow = nil }
            } message: {
                Text(Copy.allowMessage(model.pendingAllow))
            }
            .confirmationDialog(
                Copy.startSessionsQuestion(name: model.pendingStartSessionsAllow?.name ?? Copy.thisPhone),
                isPresented: Binding(
                    get: { model.pendingStartSessionsAllow != nil }, set: { if !$0 { model.pendingStartSessionsAllow = nil } }
                )
            ) {
                Button(Copy.allowConfirmTitle) { Task { await model.confirmStartSessionsAllow() } }
                Button(Copy.cancelTitle, role: .cancel) { model.pendingStartSessionsAllow = nil }
            } message: {
                Text(Copy.startSessionsMessage)
            }
            .confirmationDialog(
                Copy.permissionsQuestion(name: model.pendingPermissionsAllow?.name ?? Copy.thisPhone),
                isPresented: Binding(
                    get: { model.pendingPermissionsAllow != nil }, set: { if !$0 { model.pendingPermissionsAllow = nil } }
                )
            ) {
                Button(Copy.allowConfirmTitle) { Task { await model.confirmPermissionsAllow() } }
                Button(Copy.cancelTitle, role: .cancel) { model.pendingPermissionsAllow = nil }
            } message: {
                Text(Copy.permissionsMessage)
            }
            .confirmationDialog(
                Copy.removeQuestion(name: model.removeSubject?.name ?? Copy.thisPhone),
                isPresented: Binding(get: { model.pendingRemove != nil }, set: { if !$0 { model.pendingRemove = nil } })
            ) {
                Button(Copy.removeConfirmTitle, role: .destructive) { Task { await model.confirmRemove() } }
                Button(Copy.cancelTitle, role: .cancel) { model.pendingRemove = nil }
            } message: {
                Text(model.removeConsequence)
            }
            .confirmationDialog(
                Copy.discardQuestion,
                isPresented: Binding(get: { model.pendingDiscard != nil }, set: { if !$0 { model.pendingDiscard = nil } })
            ) {
                Button(Copy.discardConfirmTitle, role: .destructive) { Task { await model.confirmDiscard() } }
                Button(Copy.cancelTitle, role: .cancel) { model.pendingDiscard = nil }
            } message: {
                Text(Copy.discardMessage)
            }
            .alert(Copy.renameTitle, isPresented: Binding(get: { model.renaming != nil }, set: { if !$0 { model.renaming = nil } })) {
                TextField(Copy.renamePrompt, text: Binding(get: { model.renameText }, set: { model.renameText = $0 }))
                Button(Copy.saveTitle) { Task { await model.saveRename() } }
                Button(Copy.cancelTitle, role: .cancel) { model.renaming = nil }
            }
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

/// Settings → Mobile once a newer Watchtower runs the phone hub (spec §12.1):
/// one section, one row with the model's line, no toggle (go hub phase 3
/// Task 2; the guard and this view go with the Swift hub in Task 24).
struct MobileMovedView: View {
    let title: String
    let message: String

    var body: some View {
        SettingsSection(title: title) {
            SettingRow(title: message) { EmptyView() }
        }
        .padding(.vertical, Spacing.medium)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

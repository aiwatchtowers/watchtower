import SwiftUI
import WatchtowerCore

/// What a built-in's card hands back to the app: its on/off and When
/// fields live outside the recipe (the feature keys and the config file,
/// spec §5.2/§5.4), so the app writes them. Each returns why it did not
/// land, nil on success.
struct BuiltinCardActions {
    /// Turn On / Turn Off: the built-in's feature ids through the feature
    /// manager, then one daemon restart (the FEAT-03 hooks run inside
    /// `features enable`).
    var setEnabled: (_ featureIDs: [String], _ on: Bool) async -> String? = { _, _ in nil }
    /// The When fields' **Save**: config keys → text, then one daemon restart.
    var saveParameters: (_ values: [String: String]) async -> String? = { _ in nil }
}

/// A built-in automation's card (spec §5, C2 Task 10): the name with
/// **Run Now**, **Edit in Chat**, **Turn Off** / **Turn On** and **⋯**
/// (Reset to built-in, only for the owner's copy, through an inline confirm
/// row); the "Built-in version updated" banner with **Show changes** and
/// **Reset to built-in**; the unconfirmed-copy line; then **When** (its
/// fields edited in place, saved outside the recipe and its hash),
/// **Reads**, **Sends** and **Costs**. No Delete: a built-in is turned off.
struct BuiltinAutomationCard: View {
    let model: BuiltinAutomationCardModel
    /// The feature manager is applying a change (here or in Settings).
    var isApplyingFeatures = false
    var actions = BuiltinCardActions()
    /// **Edit in Chat**: the editor panel on this automation.
    let onEdit: () -> Void
    /// After a Turn On/Off or a When save: the list re-reads the row.
    var onChanged: () -> Void = {}

    /// Edited When fields by config key; only the changed ones.
    @State private var edits: [String: String] = [:]
    @State private var savingParameters = false

    static let resetConfirmLine = "Reset — your changes are lost"
    static let unconfirmedLine = "Your edited copy is not confirmed yet, so it does not run."
    static let runQueuedLine = "Runs at the next sync"
    static let updatedLine = "Built-in version updated"

    private var automation: Automation { model.automation }
    private var detail: BuiltinAutomationDetail? { model.detail }
    private var isOn: Bool { detail?.enabled ?? automation.enabled }
    private var isBusy: Bool { model.isWorking || isApplyingFeatures || savingParameters }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.page) {
                header
                notes
                if model.resetConfirming { resetConfirmRow }
                if model.updateBanner { updateBanner }
                stateLine
                if let detail { sections(detail) }
            }
            .padding(.horizontal, Spacing.page + Spacing.regular)
            .padding(.vertical, Spacing.wide)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: automation.contentHash + automation.confirmedHash) { await model.load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: Spacing.medium) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                    Text(automation.name.isEmpty ? automation.slug : automation.name)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                    Chip(text: AutomationListSections.builtinTitle, color: Color.accentColor)
                    Chip(text: isOn ? "On" : "Off", color: isOn ? Tone.success : Color.secondary)
                }
                Text(whenLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.medium)
            buttonRow
        }
    }

    /// `show`'s When line ("Every morning at the first sync after 08:00"),
    /// the trigger in words until it loads.
    private var whenLine: String {
        if let when = detail?.when, !when.isEmpty { return when }
        return AutomationTriggerText.sentence(kind: automation.triggerKind, specJSON: automation.triggerSpecJSON)
    }

    private var buttonRow: some View {
        HStack(spacing: Spacing.regular) {
            if isBusy {
                ProgressView().controlSize(.small)
            }
            if detail?.runNow == true {
                Button("Run Now") { Task { await model.runNow() } }
                    .buttonStyle(.kitPrimary)
                    .disabled(!isOn || isBusy)
                    .help(isOn ? "Run it at the next sync" : "Turn it on first")
            }
            Button("Edit in Chat", action: onEdit)
                .buttonStyle(.kitSecondary)
            Button(isOn ? "Turn Off" : "Turn On") { toggle() }
                .buttonStyle(.kitSecondary)
                .disabled(isBusy || detail?.featureIDs.isEmpty != false)
            if detail?.overridden ?? automation.overridden {
                Menu {
                    Button("Reset to built-in") { model.beginReset() }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(.kitIcon(isOn: false))
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(isBusy)
                .help("More actions")
                .accessibilityLabel("More actions")
            }
        }
        .controlSize(.small)
    }

    /// Run Now's queued note and why the last press did not land.
    @ViewBuilder private var notes: some View {
        if model.runQueued {
            Label(Self.runQueuedLine, systemImage: "clock.arrow.circlepath")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        ForEach([model.loadError, model.actionError].compactMap { $0 }, id: \.self) { message in
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(Tone.warning)
                .textSelection(.enabled)
        }
    }

    // MARK: - Reset, the update banner, the copy's state

    private var resetConfirmRow: some View {
        HStack(spacing: Spacing.cozy) {
            Image(systemName: "arrow.uturn.backward")
                .foregroundStyle(Tone.warning)
            Text(Self.resetConfirmLine)
                .font(.callout.weight(.semibold))
            Spacer()
            Button("Cancel") { model.cancelReset() }
                .buttonStyle(.kitQuiet)
            Button("Reset") {
                Task {
                    await model.confirmReset()
                    onChanged()
                }
            }
            .buttonStyle(.kitDestructive)
            .disabled(model.isWorking)
        }
        .controlSize(.small)
        .padding(Spacing.cozy)
        .card()
    }

    private var updateBanner: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack(spacing: Spacing.cozy) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                Text(Self.updatedLine)
                    .font(.callout.weight(.semibold))
                Spacer()
                Button(model.showingChanges ? "Hide changes" : "Show changes") { model.showingChanges.toggle() }
                    .buttonStyle(.kitQuiet)
                Button("Reset to built-in") { model.beginReset() }
                    .buttonStyle(.kitSecondary)
                    .disabled(model.resetConfirming || isBusy)
            }
            .controlSize(.small)
            if let changes = model.changes {
                AutomationDiffLines(diff: changes)
            }
        }
        .padding(Spacing.cozy)
        .card()
    }

    @ViewBuilder private var stateLine: some View {
        switch model.cardState {
        case .ownCopyUnconfirmed:
            Label(Self.unconfirmedLine, systemImage: "checkmark.shield")
                .font(.callout)
                .foregroundStyle(Tone.warning)
        case let .copyError(message):
            Label(message, systemImage: "exclamationmark.octagon")
                .font(.callout)
                .foregroundStyle(Tone.error)
                .textSelection(.enabled)
        case .shipped, .ownCopyConfirmed:
            EmptyView()
        }
    }

    // MARK: - When, Reads, Sends, Costs

    private func sections(_ detail: BuiltinAutomationDetail) -> some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            box(title: "When", systemImage: "clock") {
                Text(detail.when).fontWeight(.semibold)
                parameterFields(detail.parameters)
            }
            HStack(alignment: .top, spacing: Spacing.medium) {
                box(title: "Reads", systemImage: "doc.text.magnifyingglass") {
                    lines(detail.reads)
                }
                box(title: "Sends", systemImage: "paperplane") {
                    lines(detail.sends)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            box(title: "Costs", systemImage: "dollarsign.circle") {
                Text(model.costsLine)
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private func lines(_ lines: [String]) -> some View {
        if lines.isEmpty {
            Text("Nothing").foregroundStyle(.secondary)
        }
        ForEach(lines, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) }
    }

    @ViewBuilder
    private func parameterFields(_ parameters: [BuiltinAutomationDetail.Parameter]) -> some View {
        if !parameters.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                ForEach(parameters, id: \.key) { parameter in
                    Text(parameter.label).foregroundStyle(.secondary)
                    field(parameter)
                }
            }
            .controlSize(.small)
            let invalid = Self.invalidField(parameters, edits: edits)
            if let invalid {
                Text(invalid).font(.caption).foregroundStyle(Tone.error)
            }
            if Self.changed(parameters, edits: edits) {
                HStack(spacing: Spacing.regular) {
                    Button("Save") { save(parameters) }
                        .buttonStyle(.kitSecondary)
                        .disabled(invalid != nil || isBusy)
                    Button("Cancel") { edits = [:] }
                        .buttonStyle(.kitQuiet)
                        .disabled(savingParameters)
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func field(_ parameter: BuiltinAutomationDetail.Parameter) -> some View {
        let text = Binding(
            get: { edits[parameter.key] ?? parameter.value },
            set: { edits[parameter.key] = $0 == parameter.value ? nil : $0 }
        )
        switch parameter.kind {
        case .hour:
            Picker(parameter.label, selection: text) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(String(format: "%02d:00", hour)).tag(String(hour))
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(savingParameters)
        case .clock:
            TextField(parameter.label, text: text, prompt: Text("HH:MM"))
                .textFieldStyle(.kit)
                .frame(width: 64)
                .disabled(savingParameters)
        }
    }

    private func box(title: String, systemImage: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            SectionHeader(title: title, systemImage: systemImage)
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Spacing.medium)
        .card()
    }

    // MARK: - Writes

    private func toggle() {
        guard let ids = detail?.featureIDs, !ids.isEmpty else { return }
        let on = !isOn
        Task {
            let error = await actions.setEnabled(ids, on)
            model.actionError = error
            await model.load()
            onChanged()
        }
    }

    private func save(_ parameters: [BuiltinAutomationDetail.Parameter]) {
        let values = edits
        savingParameters = true
        Task {
            let error = await actions.saveParameters(values)
            model.actionError = error
            if error == nil { edits = [:] }
            await model.load()
            savingParameters = false
            onChanged()
        }
    }

    // MARK: - When fields

    /// Some field differs from the value `show` read.
    static func changed(_ parameters: [BuiltinAutomationDetail.Parameter], edits: [String: String]) -> Bool {
        parameters.contains { parameter in edits[parameter.key].map { $0 != parameter.value } ?? false }
    }

    /// The first edited field that is not a valid value, said for the owner:
    /// an hour is 0–23, a clock is HH:MM.
    static func invalidField(_ parameters: [BuiltinAutomationDetail.Parameter], edits: [String: String]) -> String? {
        for parameter in parameters {
            guard let value = edits[parameter.key] else { continue }
            switch parameter.kind {
            case .hour:
                if Int(value).map({ (0...23).contains($0) }) != true { return "\(parameter.label): pick an hour" }
            case .clock:
                if !isClock(value) { return "\(parameter.label): use HH:MM, for example 09:00" }
            }
        }
        return nil
    }

    static func isClock(_ text: String) -> Bool {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.count == 2 }),
              let hour = Int(parts[0]), let minute = Int(parts[1]) else { return false }
        return (0...23).contains(hour) && (0...59).contains(minute)
    }
}

import SwiftUI
import WatchtowerCore

/// The right panel's template (spec A3): the template's title and scope, its
/// description, one field per param (the placeholder is the param's
/// example), its notes, then each rendered recipe file as a read-only draft
/// column — the bytes **Save and Turn On** installs and confirms (AUTO-06),
/// so nothing here edits them. **Adjust in Chat** hands a one-file
/// template's text to the editor chat; a finished install calls `onDone`
/// with the first copy's id.
struct AutomationTemplatePanel: View {
    @Bindable var model: AutomationTemplatePanelModel
    let onAdjustInChat: (String) -> Void
    let onDone: (Int64) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.wide) {
                    header
                    if !model.template.params.isEmpty { paramsBlock }
                    if !model.template.notes.isEmpty { notesBlock }
                    columnsBlock
                }
                .controlSize(.small)
                .frame(maxWidth: 760, alignment: .leading)
                .padding(Spacing.page)
                .frame(maxWidth: .infinity)
            }
            footer
        }
        .task {
            if case let .done(firstID) = model.state {
                onDone(firstID)
            } else {
                await model.appear()
            }
        }
        .onChange(of: model.state) { _, state in
            if case let .done(firstID) = state { onDone(firstID) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                Text(model.template.title).font(.title3.weight(.semibold))
                Chip(text: Self.scopeTitle(model.scope), color: Color.accentColor)
            }
            if !model.template.description.isEmpty {
                Text(model.template.description)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var paramsBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            ForEach(model.template.params, id: \.key) { param in
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text(param.label).font(.callout.weight(.medium))
                    TextField(param.example, text: paramBinding(param.key))
                        .textFieldStyle(.kit)
                        .frame(maxWidth: 320)
                }
            }
        }
    }

    private var notesBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            ForEach(Array(model.template.notes.enumerated()), id: \.offset) { _, note in
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var columnsBlock: some View {
        if model.columns.isEmpty {
            if model.state == .rendering {
                HStack(spacing: Spacing.regular) {
                    ProgressView().controlSize(.small)
                    Text(AutomationDraftColumnModel.checkingLine).font(.caption).foregroundStyle(.secondary)
                }
            }
        } else if model.columns.count == 1, let column = model.columns.first {
            AutomationDraftColumn(model: column, keepAuto: .constant([]), onDryRunAgain: nil, embedded: true,
                                  showsDryRun: false)
        } else {
            ForEach(Array(model.columns.enumerated()), id: \.offset) { index, column in
                VStack(alignment: .leading, spacing: Spacing.regular) {
                    SectionHeader(title: fileTitle(index), systemImage: "doc.text")
                    AutomationDraftColumn(model: column, keepAuto: .constant([]), onDryRunAgain: nil,
                                          recipeModelID: Int64(-1 - index), embedded: true, showsDryRun: false)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .trailing, spacing: Spacing.regular) {
            stateMessage
            HStack(spacing: Spacing.regular) {
                if let hint = footerHint {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: Spacing.regular)
                if model.canAdjustInChat, let text = model.adjustText {
                    Button("Adjust in Chat") { onAdjustInChat(text) }
                        .buttonStyle(.kitSecondary)
                        .disabled(isBusy)
                } else if model.columns.count > 1 {
                    Text(AutomationTemplatePanelModel.multiFileCaption).font(.caption).foregroundStyle(.secondary)
                }
                Button { Task { await model.saveAndTurnOn() } } label: {
                    HStack(spacing: Spacing.compact) {
                        if model.state == .installing { ProgressView().controlSize(.mini) }
                        Text(primaryTitle)
                    }
                }
                .buttonStyle(.kitPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(!saveEnabled)
            }
        }
        .controlSize(.small)
        .frame(maxWidth: 760)
        .padding(.horizontal, Spacing.page)
        .padding(.vertical, Spacing.medium)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var stateMessage: some View {
        switch model.state {
        case let .failed(message):
            HStack(spacing: Spacing.regular) {
                Label(message, systemImage: "exclamationmark.octagon")
                    .foregroundStyle(Tone.error)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { Task { await model.render() } }
                    .buttonStyle(.kitQuiet)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        case let .stopped(message, _):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(Tone.warning)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .rendering, .rendered, .installing, .done:
            EmptyView()
        }
    }

    /// The Draft footer's verdict for a new recipe, with whether every
    /// file's column shows every hashed field (off otherwise, AUTO-06).
    private var draftFooter: AutomationDraftFooter {
        AutomationDraftFooter.make(
            isNew: true, bytesChanged: true, enabled: false, needsConfirmation: true,
            showsAllFields: !model.columns.isEmpty && model.columns.allSatisfy(\.showsAllFields)
        )
    }

    private var isChecking: Bool { model.isRendering || model.state == .rendering }

    private var isBusy: Bool {
        switch model.state {
        case .installing, .done, .stopped: true
        case .rendering, .rendered, .failed: false
        }
    }

    private var primaryTitle: String {
        isChecking ? AutomationDraftColumnModel.checkingLine : draftFooter.primary.title
    }

    private var saveEnabled: Bool { model.canSave && draftFooter.primaryEnabled && !isChecking }

    /// The footer's hint once a render is shown; nothing while checking, on
    /// a failure or after an install.
    private var footerHint: String? {
        guard case .rendered = model.state, !isChecking else { return nil }
        return draftFooter.hint
    }

    private func fileTitle(_ index: Int) -> String {
        model.renderedFiles.indices.contains(index) ? model.renderedFiles[index].slug : "Recipe \(index + 1)"
    }

    private func paramBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { model.params[key, default: ""] },
            set: { value in
                guard model.params[key, default: ""] != value else { return }
                model.params[key] = value
                model.paramsChanged()
            }
        )
    }

    private static func scopeTitle(_ scope: AutomationScopeChoice) -> String {
        switch scope {
        case .personal: "Personal"
        case let .workbench(_, name, _): name
        }
    }
}

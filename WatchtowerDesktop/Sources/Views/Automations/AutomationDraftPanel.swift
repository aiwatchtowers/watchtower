import SwiftUI
import WatchtowerCore

/// The live **Draft** panel next to the editor chat (spec §12.2, approved
/// mockup 2): rendered from the newest `draft_automation` result of the
/// conversation (`AutomationDraftPanelModel`), with the footer buttons.
struct AutomationDraftPanel: View {
    let model: AutomationDraftPanelModel
    /// Dry run again / Save… need a draft, a free chat and a provider with tools.
    let canAct: Bool
    let actionHelp: String?
    /// Shown above the footer once a save of this chat landed.
    var savedNote: String?
    /// Why the last footer action was not sent (`AutomationEditorChat.sendNote`).
    var sendNote: String?
    let onCancel: () -> Void
    let onDryRunAgain: () -> Void
    let onSave: () -> Void

    @State private var showingRecipe = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.isEmpty || model.isUnreadable {
                Text("Draft")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                if model.isUnreadable {
                    Label(AutomationDraftPanelModel.unreadableHint, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    Text(AutomationDraftPanelModel.emptyHint)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        heading
                        if !model.errors.isEmpty { errorsBox }
                        HStack(alignment: .top, spacing: 12) {
                            box(title: "When", value: model.when, detail: model.whenDetail)
                            box(title: "Each run may spend", value: model.budget, detail: model.lastDryRunTokens)
                        }
                        if !model.permissions.isEmpty || model.cantLine != nil { asksBox }
                        dryRunBox
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            footer
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Draft")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(model.name).font(.title3.weight(.semibold))
            }
            Spacer()
            Button("Show recipe") { showingRecipe = true }
                .buttonStyle(.link)
                .popover(isPresented: $showingRecipe, arrowEdge: .bottom) {
                    ScrollView {
                        Text(model.recipeText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .frame(width: 520, height: 420)
                    .popoverSurface()
                }
        }
    }

    private var errorsBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("The draft has errors").font(.caption.weight(.semibold)).foregroundStyle(.red)
            ForEach(Array(model.errors.enumerated()), id: \.offset) { _, error in
                Text(error).font(.callout).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func box(title: String, value: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).fontWeight(.semibold)
            if let detail {
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(.separatorColor)))
    }

    private var asksBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("It asks to").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(model.permissions, id: \.manifest) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(entry.manifest)
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    Text(entry.plain)
                }
            }
            if let cant = model.cantLine {
                Text(cant).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(.separatorColor)))
    }

    @ViewBuilder private var dryRunBox: some View {
        if !model.dryRunLines.isEmpty || model.dryRunNote != nil {
            VStack(alignment: .leading, spacing: 6) {
                Text("Dry run · nothing was written").font(.caption.weight(.semibold)).foregroundStyle(.blue)
                ForEach(Array(model.dryRunLines.enumerated()), id: \.offset) { _, line in
                    Text(line).fixedSize(horizontal: false, vertical: true)
                }
                if let note = model.dryRunNote {
                    Text(note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.blue.opacity(0.25)))
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let savedNote {
                Label(savedNote, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
            if let sendNote {
                Label(sendNote, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            HStack(alignment: .center, spacing: 12) {
                Text(AutomationDraftPanelModel.footer)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Dry run again", action: onDryRunAgain)
                    .disabled(!canAct || model.isEmpty)
                    .help(actionHelp ?? "")
                Button("Save…", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAct || model.isEmpty || model.isUnreadable || !model.errors.isEmpty)
                    .help(actionHelp ?? "")
            }
        }
    }
}

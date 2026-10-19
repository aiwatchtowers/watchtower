import SwiftUI
import WatchtowerCore

/// "New automation" (spec §12.2, approved mockup 2): **Describe in words**
/// (default) — the `automation_editor` chat with no automation yet, with the
/// live Draft panel —, **Form** — the edit form on an empty personal recipe
/// —, and **Template** — the gallery. The chat's draft survives closing the
/// sheet (its key is `AutomationsViewModel.newDraftID`); once its save lands
/// the next **+ New** starts fresh (`AppState.newAutomationEditorChat`).
/// The "For" picker (spec 2026-10-20 §4) makes it for Personal or a
/// workbench: the chat reloads per pick — each scope keeps its own draft
/// conversation —, the Template gallery installs into the picked workbench,
/// and the Form stays personal and says so.
struct NewAutomationSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case words = "Describe in words"
        case form = "Form"
        case template = "Template"

        var id: String { rawValue }
    }

    @Bindable var vm: AutomationsViewModel
    let editor: AutomationEditorCenter?
    /// The "For" picker's workbenches; with none the picker is not shown.
    let workbenches: [AutomationTemplateGallery.InstallTarget]
    /// The "For" pick: nil is Personal. The tab keeps it, so the gallery's
    /// install and a hand-back from it see the same pick.
    @Binding var workbenchID: Int64?
    let makeChat: (_ workbenchID: Int64?) async throws -> AutomationEditorChat?
    /// `<workspace>/automations`, where the **Form** tab saves; nil disables it.
    let automationsDir: String?
    let onTemplates: (() -> Void)?
    let onClose: () -> Void

    @State private var tab: Tab = .words

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("New automation").font(.title3.weight(.semibold))
                if !workbenches.isEmpty {
                    scopePicker
                }
                Spacer()
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            content
        }
        .frame(minWidth: 960, idealWidth: 1120, minHeight: 640, idealHeight: 760)
    }

    private var scopePicker: some View {
        Picker("For", selection: $workbenchID) {
            Text("Personal").tag(Int64?.none)
            ForEach(workbenches) { workbench in
                Text(workbench.name).tag(Int64?.some(workbench.id))
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("Who the automation is for: you, or one workbench's folder")
    }

    private func makePickedChat() async throws -> AutomationEditorChat? {
        try await makeChat(workbenchID)
    }

    private var pickedWorkbenchName: String? {
        workbenches.first { $0.id == workbenchID }?.name
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .words:
            // A new identity per pick: the old scope's chat closes, the
            // picked scope's own conversation opens.
            AutomationEditorChatLoader(make: makePickedChat) { chat in
                AutomationEditorChatView(chat: chat, onCancel: onClose)
            }
            .id(workbenchID)
        case .form:
            if let editor, let automationsDir {
                VStack(spacing: 0) {
                    if workbenchID != nil {
                        Label("The form makes personal automations only.", systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Spacing.page)
                            .padding(.vertical, Spacing.regular)
                    }
                    AutomationFormView(editor: editor, vm: vm, automationID: AutomationEditorCenter.newRecipeID,
                                       onChangeInWords: nil, newRecipeDir: automationsDir, onClose: onClose)
                }
            } else {
                unavailable("The form is not available until the database opens.")
            }
        case .template:
            VStack(spacing: 12) {
                Text("Start from one of the ready-made recipes.")
                    .foregroundStyle(.secondary)
                if let name = pickedWorkbenchName {
                    Text("A workbench template goes into \(name).")
                        .foregroundStyle(.secondary)
                }
                Button("Browse templates") {
                    onClose()
                    onTemplates?()
                }
                .disabled(onTemplates == nil)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func unavailable(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

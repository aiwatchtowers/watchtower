import SwiftUI
import WatchtowerCore

/// "New automation" (spec §12.2, approved mockup 2): **Describe in words**
/// (default) — the `automation_editor` chat with no automation yet, with the
/// live Draft panel —, **Form** — the edit form on an empty personal recipe
/// —, and **Template** — the gallery. The chat's draft survives closing the
/// sheet (its key is `AutomationsViewModel.newDraftID`); once its save lands
/// the next **+ New** starts fresh (`AppState.newAutomationEditorChat`).
struct NewAutomationSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case words = "Describe in words"
        case form = "Form"
        case template = "Template"

        var id: String { rawValue }
    }

    @Bindable var vm: AutomationsViewModel
    let editor: AutomationEditorCenter?
    let makeChat: () throws -> AutomationEditorChat?
    /// `<workspace>/automations`, where the **Form** tab saves; nil disables it.
    let automationsDir: String?
    let onTemplates: (() -> Void)?
    let onClose: () -> Void

    @State private var tab: Tab = .words

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("New automation").font(.title3.weight(.semibold))
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

    @ViewBuilder private var content: some View {
        switch tab {
        case .words:
            AutomationEditorChatLoader(make: makeChat) { chat in
                AutomationEditorChatView(chat: chat, onCancel: onClose)
            }
        case .form:
            if let editor, let automationsDir {
                AutomationFormView(editor: editor, vm: vm, automationID: AutomationEditorCenter.newRecipeID,
                                   onChangeInWords: nil, newRecipeDir: automationsDir, onClose: onClose)
            } else {
                unavailable("The form is not available until the database opens.")
            }
        case .template:
            VStack(spacing: 12) {
                Text("Start from one of the ready-made recipes.")
                    .foregroundStyle(.secondary)
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

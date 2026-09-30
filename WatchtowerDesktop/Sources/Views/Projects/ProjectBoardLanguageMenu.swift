import SwiftUI
import WatchtowerCore

/// The project page's "Board language" setting: which language every Claude
/// Code session writes the board's targets, intents and comments in. Empty
/// follows the session language (the default). Writes go through
/// `watchtower project update --board-language`, which validates the value.
struct ProjectBoardLanguageMenu: View {
    @Bindable var vm: ProjectsViewModel
    let project: Project
    @State private var editingCustom = false
    @State private var customText = ""

    /// Offered in the menu; any other name or tag goes through "Other…".
    private static let common = ["English", "Russian", "Ukrainian", "German", "French", "Spanish", "Polish"]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Menu {
                choice("Follow the session language", value: "")
                Divider()
                ForEach(Self.common, id: \.self) { choice($0, value: $0) }
                if !project.boardLanguage.isEmpty, !Self.common.contains(project.boardLanguage) {
                    choice(project.boardLanguage, value: project.boardLanguage)
                }
                Divider()
                Button("Other…") {
                    customText = project.boardLanguage
                    editingCustom = true
                }
            } label: {
                Text("Board language: \(project.boardLanguage.isEmpty ? "follows the session" : project.boardLanguage)")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(vm.settingBoardLanguage.contains(project.id))
            .help("The language Claude Code writes this board's targets and comments in")
            .popover(isPresented: $editingCustom, arrowEdge: .bottom) { customEditor }
            if let error = vm.boardLanguageErrors[project.id] {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
    }

    private func choice(_ title: String, value: String) -> some View {
        Button {
            set(value)
        } label: {
            if project.boardLanguage == value {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var customEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Board language").font(.headline)
            TextField("A name or tag, e.g. Portuguese or pt-BR", text: $customText)
                .frame(width: 260)
                .onSubmit(saveCustom)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { editingCustom = false }
                Button("Save", action: saveCustom).keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    private func saveCustom() {
        editingCustom = false
        set(customText)
    }

    private func set(_ language: String) {
        let id = project.id
        Task { await vm.setBoardLanguage(projectID: id, language: language) }
    }
}

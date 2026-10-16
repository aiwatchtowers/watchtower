import AppKit
import SwiftUI
import WatchtowerCore

/// The header menu's "Agent Settings…" (board #266, spec 2026-10-15 §8): the
/// workbench's methodology preset, ask guard and finish check — each "From
/// folder file" or the owner's own value — and the folder's workflow.md.
/// Every change runs `watchtower workbench methodology`; the sheet writes
/// nothing itself.
struct AgentSettingsSheet: View {
    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Agent").font(.headline)
            if let state = vm.methodology[project.id] {
                ForEach(WorkbenchMethodologyKey.allCases, id: \.self) { key in
                    setting(key, state: state)
                }
                if let note = state.installNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                fileRow(state)
            } else if vm.methodologyErrors[project.id] == nil {
                ProgressView().controlSize(.small)
            }
            if let error = vm.methodologyErrors[project.id] {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, alignment: .leading)
        .task { await vm.loadMethodology(projectID: project.id) }
    }

    private func setting(_ key: WorkbenchMethodologyKey, state: WorkbenchMethodologyState) -> some View {
        let choice = state.choice(key)
        let shown = choice == WorkbenchMethodologyKey.fromFile ? state.effective[key] : choice
        return VStack(alignment: .leading, spacing: 4) {
            Picker(key.title, selection: Binding(
                get: { choice },
                set: { change(key, to: $0) }
            )) {
                ForEach(key.choices, id: \.self) { Text(key.choiceLabel($0)).tag($0) }
            }
            .disabled(busy)
            if let line = state.effectiveLine(key) {
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
            Text(key.choiceHelp(shown))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fileRow(_ state: WorkbenchMethodologyState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(state.fileButtonTitle) {
                if state.file.present {
                    NSWorkspace.shared.open(project.folderURL.appending(path: ".watchtower/workflow.md"))
                } else {
                    createFile()
                }
            }
            .disabled(busy)
            if let note = state.fileNote {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
            Text("The team's rules for agents in this folder, committed with the code. Your settings above win over it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func change(_ key: WorkbenchMethodologyKey, to choice: String) {
        guard !busy else { return }
        busy = true
        Task {
            await vm.setMethodology(key, to: choice, projectID: project.id)
            busy = false
        }
    }

    private func createFile() {
        guard !busy else { return }
        busy = true
        Task {
            await vm.createWorkflowFile(projectID: project.id)
            busy = false
        }
    }
}

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
    @Environment(AppState.self) private var appState
    @State private var busy = false
    @State private var drafts: [InstructionField: String] = [:]
    @State private var showPreview = false

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
                instructionsSection
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
        .frame(width: 520, alignment: .leading)
        .task {
            async let methodology: Void = vm.loadMethodology(projectID: project.id)
            async let instructions: Void = vm.loadInstructions(projectID: project.id)
            _ = await (methodology, instructions)
        }
        .sheet(isPresented: $showPreview) { InstructionsPreviewSheet(workbenchID: project.id) }
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

    @ViewBuilder
    private var instructionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your instructions — this workbench").font(.subheadline.weight(.semibold))
            if let state = vm.instructions[project.id] {
                instructionField(.session, title: "Session instructions",
                                 caption: "Added after your global text in every new session here.", state: state)
                instructionField(.procedure, title: "Target procedure",
                                 caption: "Added after your global procedure when a target here goes In progress.", state: state)
                Button("Preview what the agent gets…") { showPreview = true }.buttonStyle(.link)
            } else if let error = vm.instructionErrors[project.id]?[.session] {
                Text(error).font(.caption).foregroundStyle(.red)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func instructionField(_ field: InstructionField, title: String, caption: String, state: OwnerInstructionsState) -> some View {
        InstructionFieldBlock(
            title: title, caption: caption, stored: state.workbench?.text(field) ?? "", limit: state.limit,
            suggestions: state.suggestions(for: field, workbenchID: project.id),
            detail: { "\($0.sessionCount) sessions in this workbench" },
            error: vm.instructionErrors[project.id]?[field], busy: busy,
            draft: Binding(get: { drafts[field] }, set: { drafts[field] = $0 }),
            onSave: { body in
                run { if await vm.saveInstruction(projectID: project.id, field: field, body: body) { drafts[field] = nil } }
            },
            onDecide: { row, add in
                run { await vm.decideSuggestion(projectID: project.id, field: field, id: row.id, add: add) }
            },
            globalText: state.global.text(field),
            onEditGlobal: {
                appState.settingsTab = .system
                appState.openSettingsWindow?()
            }
        )
    }

    private func run(_ work: @escaping () async -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            await work()
            busy = false
        }
    }

    private func fileRow(_ state: WorkbenchMethodologyState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Folder rules: .watchtower/workflow.md (team, committed)").font(.subheadline)
            Button(state.fileButtonTitle, action: { openOrCreateFile(state) })
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

    private func openOrCreateFile(_ state: WorkbenchMethodologyState) {
        if state.file.present {
            NSWorkspace.shared.open(project.folderURL.appending(path: ".watchtower/workflow.md"))
        } else {
            createFile()
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

import AppKit
import SwiftUI
import WatchtowerCore

/// The header menu's "Agent Settings…" (board #266, spec 2026-10-15 §8): the
/// workbench's methodology preset, ask guard and finish check — each "From
/// folder file" or the owner's own value — the folder's workflow.md and the
/// owner's instructions for this workbench. A page screen over the
/// workspace since board #1150 (the sheet no longer fit), closed by the
/// title row's **Agent Settings ✕** like the Clean Up screen. Every change
/// runs `watchtower workbench methodology` or `instructions`; the screen
/// writes nothing itself.
struct AgentSettingsScreen: View {
    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench
    @Environment(AppState.self) private var appState
    @State private var busy = false
    @State private var showPreview = false
    /// `projects.agent_analytics` of this workbench; read on appear.
    @State private var analyticsOn = false
    @State private var analyticsKnown = false
    @FocusState private var focused: Bool

    static let title = "Agent settings"
    static let subtitle = "How this workbench's agents work: their methodology, the ask guard, the finish check and your instructions."

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.wide) {
                header
                methodologySection
                instructionsSection
            }
            .frame(maxWidth: ReadableColumn.maxLineWidth, alignment: .leading)
            .padding(.horizontal, Spacing.page)
            .padding(.vertical, Spacing.large)
            .frame(maxWidth: .infinity)
        }
        .background(Surface.detail)
        // Keys go to the screen, not to the hidden terminal behind it; Esc closes.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onExitCommand { vm.closePageScreen(projectID: project.id) }
        .task(id: project.id) {
            async let methodology: Void = vm.loadMethodology(projectID: project.id)
            async let instructions: Void = vm.loadInstructions(projectID: project.id)
            _ = await (methodology, instructions)
        }
        .task(id: project.id) {
            let id = project.id
            analyticsOn = (try? await vm.dbPool.read { try HomeQueries.analyticsOnWorkbenches($0) })?.contains(id) ?? false
            analyticsKnown = true
        }
        .sheet(isPresented: $showPreview) { InstructionsPreviewSheet(workbenchID: project.id) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(Self.title).font(.headline)
            Text(Self.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Methodology

    @ViewBuilder
    private var methodologySection: some View {
        SettingsSection(title: "Agent") {
            if let state = vm.methodology[project.id] {
                VStack(alignment: .leading, spacing: Spacing.large) {
                    ForEach(WorkbenchMethodologyKey.allCases, id: \.self) { key in
                        setting(key, state: state)
                    }
                }
                if let note = state.installNote {
                    caption(note, color: Tone.warning)
                }
            } else if vm.methodologyErrors[project.id] == nil {
                ProgressView().controlSize(.small)
            }
            if let error = vm.methodologyErrors[project.id] {
                caption(error, color: Tone.error)
            }
        }
        if let state = vm.methodology[project.id] {
            SettingsSection(
                title: "Folder rules",
                footer: "The team's rules for agents in this folder, committed with the code. Your settings above win over it."
            ) {
                fileRow(state)
            }
        }
    }

    private func setting(_ key: WorkbenchMethodologyKey, state: WorkbenchMethodologyState) -> some View {
        let choice = state.choice(key)
        let shown = choice == WorkbenchMethodologyKey.fromFile ? state.effective[key] : choice
        return VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.medium) {
                Text(key.title)
                Spacer(minLength: Spacing.medium)
                Picker(key.title, selection: Binding(
                    get: { choice },
                    set: { change(key, to: $0) }
                )) {
                    ForEach(key.choices, id: \.self) { Text(key.choiceLabel($0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .disabled(busy)
            }
            if let line = state.effectiveLine(key) ?? state.carriedLine(key) {
                caption(line)
            }
            if choice == WorkbenchMethodologyKey.fromFile {
                caption(key.choiceHelp(choice))
            }
            caption(key.choiceHelp(shown))
        }
        .accessibilityElement(children: .contain)
    }

    private func fileRow(_ state: WorkbenchMethodologyState) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.medium) {
                Text(".watchtower/workflow.md (team, committed)")
                Spacer(minLength: Spacing.medium)
                Button(state.fileButtonTitle) { openOrCreateFile(state) }
                    .buttonStyle(.kitSecondary)
                    .controlSize(.small)
                    .disabled(busy)
            }
            if let note = state.fileNote {
                caption(note, color: Tone.warning)
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Instructions

    /// Outside the methodology state: a failed methodology load must not
    /// hide the owner's instructions, which load on their own.
    private var instructionsSection: some View {
        SettingsSection(title: "Your instructions — this workbench") {
            if let state = vm.instructions[project.id] {
                instructionField(.session, title: "Session instructions",
                                 caption: "Added after your global text in every new session here.", state: state)
                instructionField(.procedure, title: "Target procedure",
                                 caption: "Added after your global procedure when a target here goes In progress.", state: state)
                Button("Preview what the agent gets…") { showPreview = true }.buttonStyle(.link)
            } else if let error = vm.instructionErrors[project.id]?[.session] {
                caption(error, color: Tone.error)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func instructionField(_ field: InstructionField, title: String, caption: String, state: OwnerInstructionsState) -> some View {
        InstructionFieldBlock(
            title: title, caption: caption, stored: state.workbench?.text(field) ?? "", limit: state.limit,
            error: vm.instructionErrors[project.id]?[field], busy: busy,
            draft: Binding(
                get: { vm.agentSettingsDrafts[project.id]?[field] },
                set: { vm.agentSettingsDrafts[project.id, default: [:]][field] = $0 }
            ),
            onSave: { body in
                run {
                    if await vm.saveInstruction(projectID: project.id, field: field, body: body) {
                        vm.agentSettingsDrafts[project.id]?[field] = nil
                    }
                }
            },
            coachPointer: coachPointer,
            globalText: state.global.text(field),
            onEditGlobal: openGlobalSettings
        )
    }

    static func coachPointerText(analyticsOn: Bool) -> String {
        analyticsOn ? "Suggestions for this workbench come from the coach." : "Turn on Analytics to get the coach's suggestions."
    }

    /// Nothing until the Analytics state is read, so an off workbench never
    /// flashes the "come from the coach" line.
    private var coachPointer: CoachPointer? {
        guard analyticsKnown else { return nil }
        return CoachPointer(text: Self.coachPointerText(analyticsOn: analyticsOn)) {
            appState.openCoachInAnalytics(workbench: project.id)
        }
    }

    private func caption(_ text: String, color: Color = .secondary) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func openGlobalSettings() {
        appState.settingsTab = .system
        appState.openSettingsWindow?()
    }

    private func openOrCreateFile(_ state: WorkbenchMethodologyState) {
        if state.file.present {
            NSWorkspace.shared.open(project.folderURL.appending(path: ".watchtower/workflow.md"))
        } else {
            run { await vm.createWorkflowFile(projectID: project.id) }
        }
    }

    private func change(_ key: WorkbenchMethodologyKey, to choice: String) {
        run { await vm.setMethodology(key, to: choice, projectID: project.id) }
    }

    private func run(_ work: @escaping () async -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            await work()
            busy = false
        }
    }
}

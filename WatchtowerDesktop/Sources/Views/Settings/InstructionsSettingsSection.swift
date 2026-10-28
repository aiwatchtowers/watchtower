import DesignKit
import SwiftUI
import WatchtowerCore

/// Settings → Profile → Instructions: the owner's texts. "For chats and
/// agents" (the global session text), "Only in chats" (the chat text and the
/// lines added from chats), "Target procedure". Per-workbench texts stay in
/// Agent Settings….
struct InstructionsSettingsSection: View {
    @Environment(AppState.self) private var appState

    @State private var model = InstructionsSettingsModel(cli: nil)
    @State private var showPreview = false

    var body: some View {
        Group {
            if let state = model.state {
                fieldBlock(.session, title: "For chats and agents",
                           caption: "Every chat and every new workbench session starts with this. Workbenches can add their own.", state: state,
                           coachPointer: CoachPointer(text: Self.coachPointerText) {
                               Task { await appState.openCoachInAnalyticsFromSettings() }
                           })
                fieldBlock(.chat, title: "Only in chats",
                           caption: "Added to every chat, never to a workbench session. \"remember: …\" in a chat adds a line here.", state: state)
                addedFromChats(state.chatLines)
                fieldBlock(.procedure, title: "Target procedure",
                           caption: "How to work any target. The agent gets it each time it moves a target to In progress.", state: state)
                Button("Preview what the agent gets…") { showPreview = true }
                    .buttonStyle(.link)
            } else if let loadError = model.loadError {
                Text(loadError).font(.caption).foregroundStyle(Tone.error)
            }
            if let notice = model.notice {
                Text(notice).font(.caption).foregroundStyle(Tone.warning)
            }
        }
        .task {
            model.replaceCLI(ProcessCLIRunner.makeDefault().map { WorkbenchCLI(runner: $0) })
            await model.load()
        }
        .onChange(of: appState.embeddedChats.rememberCenter?.revision) {
            Task { await model.rememberRevisionChanged() }
        }
        .sheet(isPresented: $showPreview) { InstructionsPreviewSheet(workbenchID: nil) }
    }

    static let coachPointerText = "Suggestions now come from the coach — see a workbench's Analytics."

    private func fieldBlock(
        _ field: InstructionField,
        title: String,
        caption: String,
        state: OwnerInstructionsState,
        coachPointer: CoachPointer? = nil
    ) -> some View {
        InstructionFieldBlock(
            title: title, caption: caption, stored: state.global.text(field), limit: state.limit,
            error: model.errors[field], busy: model.busy,
            draft: Binding(get: { model.drafts[field] }, set: { model.drafts[field] = $0 }),
            onSave: { body in Task { await model.save(field, body: body) } },
            coachPointer: coachPointer
        )
    }

    @ViewBuilder
    private func addedFromChats(_ lines: [OwnerInstructionChatLine]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text("Added from chats").font(.caption.weight(.semibold))
                ForEach(lines) { line in
                    HStack(alignment: .firstTextBaseline) {
                        Text(line.line).font(.caption)
                        Spacer()
                        if let id = InstructionsSettingsModel.openChatTarget(line) {
                            Button("Open chat") { appState.openChatConversation(id) }
                                .buttonStyle(.link).font(.caption)
                        }
                    }
                }
            }
        }
    }
}

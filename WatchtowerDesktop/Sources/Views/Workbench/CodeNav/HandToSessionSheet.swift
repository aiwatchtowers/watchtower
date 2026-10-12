import SwiftUI
import WatchtowerCore

/// Hand to Session (⌥⌘↩, spec 2026-10-02 §9.5; board #399): what will be
/// sent, and where — a running agent session of the workbench (Claude Code
/// or Codex) or a new one of either agent. Send is the confirmation; a
/// session waiting on a permission prompt is shown but cannot be picked (a
/// Return would answer it), nor can a new session of an agent not installed.
struct HandToSessionSheet: View {
    let handoff: CodeHandoffCenter
    let request: CodeHandoffRequest
    @State private var target: CodeHandoffTarget?
    @State private var sending = false

    var body: some View {
        let workbenchID = request.project.id
        let choices = handoff.choices(workbenchID: workbenchID)
        VStack(alignment: .leading, spacing: 12) {
            Text("Hand to Session").font(.headline)
            ScrollView {
                Text(request.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 180)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Picker("Send to", selection: Binding(
                get: { target ?? handoff.defaultTarget(workbenchID: workbenchID) },
                set: { target = $0 }
            )) {
                ForEach(choices) { choice in
                    Text(label(choice))
                        .tag(CodeHandoffTarget.session(choice.id))
                        .selectionDisabled(choice.isWaitingForApproval)
                }
                ForEach(handoff.newSessionChoices(workbenchID: workbenchID)) { choice in
                    Text(choice.title)
                        .tag(CodeHandoffTarget.newSession(choice.agent))
                        .selectionDisabled(!choice.isAvailable)
                }
            }
            .pickerStyle(.radioGroup)
            Text(note(choices))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = handoff.errors[workbenchID] {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { handoff.cancel(workbenchID: workbenchID) }
                    .keyboardShortcut(.cancelAction)
                    .disabled(sending)
                Button("Send") { send(workbenchID) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sending)
            }
        }
        .padding(16)
        .frame(width: 480)
    }

    private func label(_ choice: CodeHandoffSessionChoice) -> String {
        let title = choice.session.title + (choice.session.kind == .codex ? " (Codex)" : "")
        guard !choice.isWaitingForApproval else { return title + " — waiting for a permission answer" }
        let caption = SessionStatePresentation.caption(for: choice.state).lowercased()
        return title + " — " + caption
    }

    private func note(_ choices: [CodeHandoffSessionChoice]) -> String {
        let running = choices.isEmpty ? "No agent session of this workbench is running. " : ""
        return running + "A session idle at its prompt gets the text and Return; a working one gets the text and you press Return; "
            + "a new session starts with it. "
            + "Only the question, the answer and file:line references are sent."
    }

    private func send(_ workbenchID: Int64) {
        let chosen = target ?? handoff.defaultTarget(workbenchID: workbenchID)
        sending = true
        Task {
            await handoff.send(to: chosen, workbenchID: workbenchID)
            sending = false
        }
    }
}

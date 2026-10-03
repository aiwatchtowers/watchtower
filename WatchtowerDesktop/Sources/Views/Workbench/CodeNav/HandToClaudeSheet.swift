import SwiftUI
import WatchtowerCore

/// Hand to Claude Code (⌥⌘↩, spec 2026-10-02 §9.5): what will be sent, and
/// where — a running Claude Code session of the workbench or a new one.
/// Send is the confirmation; a session waiting on a permission prompt is
/// shown but cannot be picked (a Return would answer it).
struct HandToClaudeSheet: View {
    let handoff: CodeHandoffCenter
    let request: CodeHandoffRequest
    @State private var target: CodeHandoffTarget?
    @State private var sending = false

    var body: some View {
        let workbenchID = request.project.id
        let choices = handoff.choices(workbenchID: workbenchID)
        VStack(alignment: .leading, spacing: 12) {
            Text("Hand to Claude Code").font(.headline)
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
                Text("New session").tag(CodeHandoffTarget.newSession)
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
        guard !choice.isWaitingForApproval else { return choice.session.title + " — waiting for a permission answer" }
        let caption = SessionStatePresentation.caption(for: choice.state).lowercased()
        return choice.session.title + " — " + caption
    }

    private func note(_ choices: [CodeHandoffSessionChoice]) -> String {
        let running = choices.isEmpty ? "No Claude Code session of this workbench is running. " : ""
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

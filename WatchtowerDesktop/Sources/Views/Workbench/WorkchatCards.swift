import SwiftUI
import WatchtowerCore
import WatchtowerSync

/// The session's pending permission prompt at the end of the Workchat feed
/// (#711, spec §4 state 2): what the agent wants to do, then **Allow**,
/// **Deny** and **Show in Terminal**. A prompt only a deny may answer here
/// (`PermissionAllowBlock`) has no Allow.
struct WorkchatPermissionCard: View {
    let model: WorkchatModel
    let prompt: SessionControl.PermissionPrompt
    let onShowTerminal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(Self.title(toolName: prompt.toolName))
                .fontWeight(.semibold)
                .foregroundStyle(.orange)
            Text(prompt.summary)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            if let block = prompt.allowBlock {
                Text(Self.note(block))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if prompt.allowBlock == nil {
                    Button("Allow") { answer(true) }
                        .buttonStyle(.borderedProminent)
                }
                Button("Deny") { answer(false) }
                Button("Show in Terminal", action: onShowTerminal)
            }
            .disabled(model.answering)
            if let error = model.permissionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.5)))
    }

    private func answer(_ allow: Bool) {
        Task { await model.answer(allow: allow) }
    }

    static func title(toolName: String) -> String {
        switch toolName {
        case "Bash": "Claude wants to run a command"
        case "Edit", "Write", "NotebookEdit": "Claude wants to edit a file"
        default: toolName.isEmpty ? "Claude asks for permission" : "Claude wants to use \(toolName)"
        }
    }

    /// Why Allow is missing, in the Mac's words (the phone's `note` sends
    /// the owner to the Mac).
    static func note(_ block: PermissionAllowBlock) -> String {
        switch block {
        case .clipped: "Shortened here: allow it in the terminal, where the whole request shows."
        case .settingsPath: "Changes Watchtower or shell settings: allow it in the terminal."
        }
    }
}

/// One open ask of the session at the end of the feed (spec §4 state 4):
/// kind and `Ask #N`, the title, and **Open Ask**, which opens the drawer.
struct WorkchatAskCard: View {
    let ask: OwnerAsk
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask #\(ask.id) · \(OwnerAskPresentation.askKindLabel(ask.kind))")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.purple)
            Text(ask.title)
                .fontWeight(.semibold)
                .textSelection(.enabled)
            Button("Open Ask", action: onOpen)
                .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.purple.opacity(0.45)))
    }
}

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
        VStack(alignment: .leading, spacing: Spacing.compact) {
            Text(Self.title(toolName: prompt.toolName))
                .fontWeight(.semibold)
                .foregroundStyle(.orange)
            Text(prompt.summary)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.regular)
                .padding(.vertical, Spacing.compact)
                .background(Surface.text, in: RoundedRectangle(cornerRadius: Radius.control))
            if let block = prompt.allowBlock {
                Text(Self.note(block))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: Spacing.compact) {
                if prompt.allowBlock == nil {
                    Button("Allow") { answer(true) }
                        .buttonStyle(.kitPrimary)
                }
                Button("Deny") { answer(false) }
                    .buttonStyle(.kitSecondary)
                Button("Show in Terminal", action: onShowTerminal)
                    .buttonStyle(.kitSecondary)
            }
            .disabled(model.answering)
            if let error = model.permissionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(Spacing.cozy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(ChipTint.fillOpacity), in: RoundedRectangle(cornerRadius: Radius.container))
        .overlay(RoundedRectangle(cornerRadius: Radius.container)
            .strokeBorder(Color.orange.opacity(ChipTint.strokeOpacity)))
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
        VStack(alignment: .leading, spacing: Spacing.compact) {
            Text("Ask #\(ask.id) · \(OwnerAskPresentation.askKindLabel(ask.kind))")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.purple)
            Text(ask.title)
                .fontWeight(.semibold)
                .textSelection(.enabled)
            Button("Open Ask", action: onOpen)
                .buttonStyle(.kitPrimary)
        }
        .padding(Spacing.cozy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Radius.container)
            .strokeBorder(Color.purple.opacity(ChipTint.strokeOpacity)))
    }
}

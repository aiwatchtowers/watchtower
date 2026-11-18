import SwiftUI
import WatchtowerCore

/// The top of a session's pane while an agent's message may still sit typed
/// in its prompt (spec 2026-11-18 §6.6, D40): the notice, Show in Terminal,
/// and — only with a session host that cannot tell the prompt was cleared
/// (no `prompt_state`) — a quiet Dismiss, which goes through the CLI.
struct SessionPromptNotice: View {
    let vm: WorkbenchesViewModel
    let projectID: Int64
    let sessionID: Int64

    var body: some View {
        if vm.sessionStatuses[sessionID]?.messageInPrompt == true {
            VStack(spacing: 0) {
                HStack(spacing: Spacing.compact) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Tone.warning)
                        .accessibilityHidden(true)
                    Text(SessionNestingPresentation.promptNotice)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Spacing.small)
                    Button(SessionNestingPresentation.showInTerminal) {
                        Task { await vm.showTerminal(sessionID: sessionID, projectID: projectID) }
                    }
                    .buttonStyle(.kitSecondary)
                    .fixedSize()
                    if vm.promptNoticeOffersDismiss {
                        Button(SessionNestingPresentation.dismiss) {
                            Task { await vm.dismissPromptMessages(sessionID: sessionID, projectID: projectID) }
                        }
                        .buttonStyle(.kitQuiet)
                        .fixedSize()
                    }
                }
                .font(.callout)
                .padding(.horizontal, Spacing.medium)
                .padding(.vertical, Spacing.regular)
                .background(Tone.warning.opacity(0.12))
                .accessibilityElement(children: .contain)
                Divider()
            }
        }
    }
}

/// A sub-session's way back on its strip (§6.5): `↖ from “<parent title>”`,
/// a click opens the parent. Nothing for a top-level session or one whose
/// parent is gone.
struct SessionFromParentLink: View {
    let vm: WorkbenchesViewModel
    let projectID: Int64
    let sessionID: Int64

    var body: some View {
        if let parent = vm.parentSession(of: sessionID, projectID: projectID) {
            Button(SessionNestingPresentation.fromParent(title: parent.title)) {
                Task { await vm.showSession(id: parent.id) }
            }
            .buttonStyle(.kitQuiet)
            .foregroundStyle(Color.accentColor)
            .lineLimit(1)
            .truncationMode(.middle)
            .help("Open the session that started this one")
        }
    }
}

/// The strip's folder crumb (`📁 hub`) of a session on a bench of several
/// folders; its tooltip is the whole trail (§6.5).
struct SessionFolderCrumb: View {
    let vm: WorkbenchesViewModel
    let project: Workbench
    let sessionID: Int64

    var body: some View {
        if let name = vm.sessionFolderName(sessionID: sessionID, projectID: project.id) {
            HStack(spacing: 4) {
                Text("›")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                SessionFolderLabel(name: name, font: .caption)
            }
            .help(vm.stripTrail(sessionID: sessionID, project: project, folder: name))
        }
    }
}

import SwiftUI
import WatchtowerCore

/// What the Inbox header and the root's ⋯ open in the reading pane: the
/// reaction cheat sheet (`?`), and the two editors the old Learned / Profile
/// segments held (R7) — Learned Rules (INBOX-05) and Assistant Profile.
/// Nothing in the Inbox header is a pop-up.
enum InboxAuxPane: Equatable {
    case reactionCommands, learnedRules, profile

    var title: String {
        switch self {
        case .reactionCommands: "Reaction Commands"
        case .learnedRules: "Learned Rules"
        case .profile: "Assistant Profile"
        }
    }
}

/// The inline row the Idea finder opens under its list header.
enum InboxIdeasRow: Equatable {
    case newIdea, findIdeas
}

/// The Idea finder list's header control: `+` opens the New idea row; while a
/// backfill mines, a Mining… mark opens its row again.
struct InboxIdeasHeader: View {
    let isMining: Bool
    @Binding var row: InboxIdeasRow?

    var body: some View {
        HStack(spacing: Spacing.regular) {
            Button { row = .newIdea } label: { Image(systemName: "plus") }
                .buttonStyle(.kitIcon(isOn: row == .newIdea))
                .help("New Idea")
                .accessibilityLabel("New Idea")
            if isMining {
                Button { row = .findIdeas } label: {
                    HStack(spacing: Spacing.small) {
                        ProgressView().controlSize(.small)
                        Text("Mining…").font(.caption)
                    }
                }
                .buttonStyle(.kitQuiet)
                .help("Finding ideas in past messages")
            }
        }
    }
}

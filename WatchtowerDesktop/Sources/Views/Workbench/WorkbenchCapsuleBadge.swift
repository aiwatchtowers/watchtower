import SwiftUI

/// White semibold text on a blue capsule: a session's `#id`, a workbench's
/// new-comments count.
struct WorkbenchCapsuleBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.blue, in: Capsule())
    }
}

/// A session's agent when it is not Claude Code ("Codex", board #399): small
/// secondary text in an outlined capsule, quieter than the `#id` badge.
struct AgentTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 4)
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 0.5))
            .help("This session runs \(text)")
    }
}

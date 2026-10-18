import SwiftUI

/// A small tinted capsule: a card's priority or status, and the side panel's
/// drift findings.
struct Chip: View {
    let text: String
    let color: Color
    var dot = false

    var body: some View {
        HStack(spacing: 4) {
            if dot {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(text).font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(dot ? Color.primary : color)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// White semibold text on a blue capsule: a session's `#id`, a workbench's
/// new-comments count.
struct CountBadge: View {
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
struct OutlineTag: View {
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

/// A status or priority menu's label: a tinted capsule with an icon and a
/// chevron, so it reads as a control rather than a bare tag.
struct MenuLabel: View {
    let text: String
    let systemImage: String
    let color: Color
    /// A read-only value (a group's status) drops the chevron.
    var isMenu = true

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption2)
                .foregroundStyle(color)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
            if isMenu {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.3), lineWidth: 0.5))
    }
}

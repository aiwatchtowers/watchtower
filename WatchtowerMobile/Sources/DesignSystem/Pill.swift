import SwiftUI

/// A small capsule label (design pass spec §2.6). Tinted: the tone at 0.14
/// under the tone's text. Neutral: secondary on secondary at 0.12.
/// Monospaced only for branch names.
struct Pill: View {
    enum Style {
        case tinted, neutral
    }

    let text: String
    var tone: PhoneTone = .secondary
    var style: Style = .tinted
    var monospaced = false

    var body: some View {
        Text(text)
            .font(monospaced ? Font.caption2.monospaced() : TypeScale.pill)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(style == .tinted ? tone.color : Color.secondary)
            .background(style == .tinted ? tone.color.opacity(0.14) : Color.secondary.opacity(0.12), in: Capsule())
    }
}

/// The Mac's sidebar badge (`SidebarView.swift:262-270`): a white count on a
/// solid capsule in the tone, at least 16 pt wide.
struct CountBadge: View {
    let count: Int
    let tone: PhoneTone

    var body: some View {
        Text("\(count)")
            .font(TypeScale.badge)
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .frame(minWidth: 16)
            .background(tone.color, in: Capsule())
    }
}

/// A filter chip: the title and its count, a capsule inset by 7 inside a
/// 44 pt tall hit area, accent when selected.
struct FilterChip: View {
    let title: String
    let count: Int?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.small) {
                Text(title)
                if let count {
                    Text("\(count)").monospacedDigit()
                }
            }
            .font(.footnote)
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12), in: Capsule().inset(by: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

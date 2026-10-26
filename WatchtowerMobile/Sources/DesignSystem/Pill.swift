import SwiftUI

/// One chip's data: the text, its tone and the Desktop `Chip`'s leading dot
/// (a priority chip).
struct PillItem: Equatable {
    let text: String
    let tone: PhoneTone
    var dot = false
}

/// A small capsule label, the Desktop's `Chip` (mockups 5, 9): the tone at
/// `ChipTint.fillOpacity` inside a `ChipTint.strokeOpacity` hairline, the
/// text in the tone, an optional leading dot. Neutral: secondary on the same
/// recipe. Monospaced only for branch names.
///
///     Pill(item: PillItem(text: "High", tone: .red, dot: true))
///     Pill(text: "feature/x", style: .neutral, monospaced: true)
struct Pill: View {
    enum Style {
        case tinted, neutral
    }

    struct Paint: Equatable {
        let fill: Color
        let stroke: Color
        let text: Color
    }

    let text: String
    var tone: PhoneTone = .secondary
    var style: Style = .tinted
    var monospaced = false
    var dot = false

    init(text: String, tone: PhoneTone = .secondary, style: Style = .tinted, monospaced: Bool = false, dot: Bool = false) {
        self.text = text
        self.tone = tone
        self.style = style
        self.monospaced = monospaced
        self.dot = dot
    }

    init(item: PillItem) {
        self.init(text: item.text, tone: item.tone, dot: item.dot)
    }

    static func paint(_ style: Style, tone: PhoneTone) -> Paint {
        let color = style == .tinted ? tone.color : Color.secondary
        return Paint(fill: color.opacity(ChipTint.fillOpacity), stroke: color.opacity(ChipTint.strokeOpacity), text: color)
    }

    var body: some View {
        let paint = Self.paint(style, tone: tone)
        HStack(spacing: Spacing.small) {
            if dot {
                Circle().fill(paint.text).frame(width: PhoneMetrics.priorityDot, height: PhoneMetrics.priorityDot)
            }
            Text(text)
                .font(monospaced ? Font.caption2.monospaced() : TypeScale.pill)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, Spacing.compact)
        .padding(.vertical, Spacing.tight)
        .foregroundStyle(paint.text)
        .background(paint.fill, in: Capsule())
        .overlay(Capsule().strokeBorder(paint.stroke, lineWidth: ChipTint.strokeWidth))
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

/// A filter chip: the title and its count, a capsule inset by 8 inside a
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
            .padding(.horizontal, Spacing.cozy)
            .frame(minHeight: PhoneMetrics.minTouch)
            .background(isSelected ? Fill.selected : Fill.card, in: Capsule().inset(by: Spacing.regular))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

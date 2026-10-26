import SwiftUI
import WatchtowerCore

/// A switcher popover's row (the workbench switcher, the Chats project
/// switcher): a check on the current one (the row highlighted), the name on
/// the full width over the state segments; the tooltip (a folder) carries
/// the rest, so the state never squeezes the name.
struct SwitcherPopoverRow: View {
    let name: String
    let isCurrent: Bool
    let tooltip: String
    let segments: [SwitcherSegment]
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Spacing.compact) {
                Image(systemName: "checkmark")
                    .font(.caption)
                    .opacity(isCurrent ? 1 : 0)
                    .accessibilityHidden(!isCurrent)
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(name)
                        .font(.callout.weight(isCurrent ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !segments.isEmpty {
                        HStack(spacing: Spacing.compact) {
                            SwitcherStateSegments(segments: segments)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.compact)
            .frame(minHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: Radius.mark)
                    .fill(isCurrent ? Fill.selected : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// A switcher row's state text (`SwitcherSegment`): the badge tone as a
/// blue count badge, warning in orange, the rest grey. No stack of its own:
/// the caller lays the segments out (the row's line, the go-to palette's
/// trailing edge).
struct SwitcherStateSegments: View {
    let segments: [SwitcherSegment]

    var body: some View {
        ForEach(segments, id: \.text) { segment in
            segmentView(segment)
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: SwitcherSegment) -> some View {
        switch segment.tone {
        case .badge:
            CountBadge(text: segment.text)
        case .warning:
            Text(segment.text).font(.caption2).foregroundStyle(Tone.warning).lineLimit(1).fixedSize()
        case .secondary:
            Text(segment.text).font(.caption2).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
    }
}

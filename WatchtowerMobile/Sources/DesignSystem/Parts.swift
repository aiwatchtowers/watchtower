import SwiftUI

/// A session's state dot: filled while the process runs, a ring otherwise,
/// in the Mac's tone.
struct SessionDot: View {
    let tone: PhoneTone
    let isRing: Bool
    var size: CGFloat = 9

    var body: some View {
        Group {
            if isRing {
                Circle().strokeBorder(tone.color, lineWidth: 1.5)
            } else {
                Circle().fill(tone.color)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A thin progress bar in the model's tone.
struct ThinProgressBar: View {
    let value: Double
    let tone: PhoneTone
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(tone.color)
                    .frame(width: proxy.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: height)
        .accessibilityLabel("\(Int((value * 100).rounded())) percent")
    }
}

/// One step of a progress list (design pass spec §2.11): the Saved
/// recording, the session start, onboarding's link steps. The icon column
/// is 22 pt; a row is at least 44 pt tall.
struct StepRow: View {
    enum State: Equatable {
        case done, current, waiting, todo, failed
    }

    let state: State
    let text: String

    var body: some View {
        HStack(spacing: Spacing.medium) {
            icon.frame(width: 22)
            Text(text)
                .font(.body)
                .foregroundStyle(state == .todo ? Color.secondary : Color.primary)
        }
        .frame(minHeight: 44, alignment: .leading)
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(PhoneTone.green.color)
        case .current: ProgressView()
        case .waiting: Image(systemName: "moon.zzz").foregroundStyle(.secondary)
        case .todo: Image(systemName: "circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(PhoneTone.red.color)
        }
    }
}

/// A wrapping row: items 6 pt apart, lines 4 pt apart. Replaces the
/// HStack-or-VStack `ViewThatFits` fallbacks, which went one item per line.
struct FlowRow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        Self.arrange(
            sizes: subviews.map { $0.sizeThatFits(.unspecified) },
            maxWidth: proposal.width ?? .infinity, spacing: spacing, lineSpacing: lineSpacing
        ).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = Self.arrange(
            sizes: subviews.map { $0.sizeThatFits(.unspecified) },
            maxWidth: bounds.width, spacing: spacing, lineSpacing: lineSpacing
        )
        for (subview, frame) in zip(subviews, layout.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    /// Line breaking: an item starts a new line when it would pass
    /// `maxWidth`; an item wider than `maxWidth` gets a line of its own at
    /// `maxWidth` (so it truncates instead of overflowing).
    static func arrange(sizes: [CGSize], maxWidth: CGFloat, spacing: CGFloat, lineSpacing: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var width: CGFloat = 0
        for size in sizes {
            let item = CGSize(width: min(size.width, maxWidth), height: size.height)
            if cursorX > 0, cursorX + item.width > maxWidth {
                cursorY += lineHeight + lineSpacing
                cursorX = 0
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: cursorX, y: cursorY), size: item))
            width = max(width, cursorX + item.width)
            cursorX += item.width + spacing
            lineHeight = max(lineHeight, item.height)
        }
        return (frames, CGSize(width: width, height: frames.isEmpty ? 0 : cursorY + lineHeight))
    }
}

import SwiftUI

/// A session's state dot, the Desktop's `SessionLiveDot`: `circle.fill`
/// while the process runs, `circle` (a ring) otherwise, in the Mac's tone;
/// `pulses` while background agents run, still under Reduce Motion.
/// Decorative: the row's caption reads the state.
///
///     SessionDot(tone: row.tone, isRing: row.isRing)
struct SessionDot: View {
    let tone: PhoneTone
    let isRing: Bool
    var pulses = false
    var size = PhoneMetrics.sessionDot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func symbol(isRing: Bool) -> String {
        isRing ? "circle" : "circle.fill"
    }

    var body: some View {
        Image(systemName: Self.symbol(isRing: isRing))
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(tone.color)
            .symbolEffect(.pulse, isActive: pulses && !reduceMotion)
            .accessibilityHidden(true)
    }
}

/// A state's glyph as the mockups draw it (1, 2, 4): a white SF Symbol on a
/// disc in the tone ("?" waiting on an ask, a raised hand for an approval,
/// a check for finished). Decorative: the caption beside it reads the
/// state.
///
///     StateMark(glyph: "questionmark", tone: .waitingForYou)
struct StateMark: View {
    let glyph: String
    let tone: PhoneTone
    var size = PhoneMetrics.iconColumn

    var body: some View {
        Circle()
            .fill(tone.color)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: glyph)
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .padding(size / 4)
            }
            .accessibilityHidden(true)
    }
}

/// A thin progress bar in the model's tone, on the card fill (mockup
/// `.bar`).
struct ThinProgressBar: View {
    let value: Double
    let tone: PhoneTone
    var height = PhoneMetrics.progressBar

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Fill.card)
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

        /// What VoiceOver reads after the step's text.
        var accessibilityValue: String {
            switch self {
            case .done: "Done"
            case .current, .waiting: "In progress"
            case .todo: "Not started"
            case .failed: "Failed"
            }
        }
    }

    let state: State
    let text: String

    var body: some View {
        HStack(spacing: Spacing.medium) {
            icon.frame(width: PhoneMetrics.stepColumn)
            Text(text)
                .font(.body)
                .foregroundStyle(state == .todo ? Color.secondary : Color.primary)
        }
        .frame(minHeight: PhoneMetrics.minTouch, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityValue(state.accessibilityValue)
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
    var spacing = Spacing.compact
    let lineSpacing = Spacing.small

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

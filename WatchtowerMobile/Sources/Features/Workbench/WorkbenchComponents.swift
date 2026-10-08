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

/// A thin progress bar in the accent colour.
struct ThinProgressBar: View {
    let value: Double
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(PhoneTone.accent.color)
                    .frame(width: proxy.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: height)
        .accessibilityLabel("\(Int((value * 100).rounded())) percent")
    }
}

/// A small count pill: orange for waiting and asks, as spec §14 allows.
struct CountPill: View {
    let text: String
    let tone: PhoneTone

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(tone.color)
            .background(tone.color.opacity(0.15), in: Capsule())
    }
}

/// A session-state count with its dot: "● 2 working".
struct SessionCountLabel: View {
    let count: SessionStateCount

    var body: some View {
        HStack(spacing: 4) {
            SessionDot(tone: count.tone, isRing: count.isRing, size: 7)
            Text(count.text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// One Waiting-for-you card, orange-tinted.
struct WaitingCardView: View {
    let card: WaitingCardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(card.kindLabel)
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(PhoneTone.orange.color)
            Text(card.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            Text(card.subline)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(PhoneTone.orange.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

/// One SESSIONS row: dot, title, coloured state label, report line with a
/// mini progress bar, open-ask pill and "▸ N closed".
struct SessionRowView: View {
    let row: SessionRowModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SessionDot(tone: row.tone, isRing: row.isRing)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let glyph = row.glyph {
                        Image(systemName: glyph)
                    }
                    Text(row.caption)
                }
                .font(.subheadline)
                .foregroundStyle(row.tone.color)
                .lineLimit(1)
                if let report = row.reportLine {
                    HStack(spacing: 6) {
                        Text(report)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let progress = row.reportProgress {
                            ThinProgressBar(value: progress, height: 3)
                                .frame(width: 40)
                        }
                    }
                }
                if let closed = row.closedLabel {
                    Text(closed)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if row.openAsks > 0 {
                CountPill(text: "\(row.openAsks)", tone: .orange)
                    .accessibilityLabel(row.openAsks == 1 ? "1 open ask" : "\(row.openAsks) open asks")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

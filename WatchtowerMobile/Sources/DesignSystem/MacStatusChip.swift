import SwiftUI

/// Where the Mac is, as the chip says it. Task 13's reachability maps onto
/// this; the chip needs nothing else.
enum MacChipState: Equatable {
    case online
    /// Heard from recently enough to be asleep rather than gone.
    case asleep(lastSeen: Date)
    case offline(lastSeen: Date?)
    case notLinked
}

/// The Mac status chip of Now and the Calendar's header (mockups 1, 7):
/// "MacBook Pro · online" green, "… · asleep · last seen 12 min ago" gray,
/// "… · offline" secondary, "No Mac linked". A Mac with no name is "Mac".
/// Never orange.
struct MacStatusChipModel: Equatable {
    let text: String
    let tone: PhoneTone

    init(macName: String, state: MacChipState, now: Date) {
        let name = macName.isEmpty ? "Mac" : macName
        switch state {
        case .online:
            text = "\(name) · online"
            tone = .green
        case let .asleep(lastSeen):
            text = "\(name) · asleep · last seen \(LastSeen.phrase(lastSeen, now: now))"
            tone = .gray
        case let .offline(lastSeen):
            text = "\(name) · offline" + (lastSeen.map { " · last seen \(LastSeen.phrase($0, now: now))" } ?? "")
            tone = .secondary
        case .notLinked:
            text = "No Mac linked"
            tone = .secondary
        }
    }

    var toneUse: ToneUse {
        ToneUse(element: "mac status chip", tone: tone, role: .mac)
    }
}

/// The chip: a dot in the tone and the text in `.caption` secondary on a
/// `Fill.rest` capsule, inside a 44 pt tall hit area (wrap it in a Button
/// or a NavigationLink to open the Macs).
///
///     MacStatusChip(model: MacStatusChipModel(macName: name, state: .online, now: date))
struct MacStatusChip: View {
    let model: MacStatusChipModel

    var body: some View {
        HStack(spacing: Spacing.compact) {
            Circle()
                .fill(model.tone.color)
                .frame(width: PhoneMetrics.macDot, height: PhoneMetrics.macDot)
            Text(model.text)
                .font(TypeScale.meta)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, Spacing.small)
        .padding(.leading, Spacing.regular)
        .padding(.trailing, Spacing.cozy)
        .background(Fill.rest, in: Capsule())
        .frame(minHeight: PhoneMetrics.minTouch)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.text)
    }
}

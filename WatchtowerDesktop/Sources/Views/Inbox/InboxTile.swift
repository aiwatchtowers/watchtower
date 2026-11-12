import SwiftUI
import WatchtowerCore

/// A row's kind on a soft square (spec "The list"): the kind's symbol in its
/// tint over the tint at `ChipTint.fillOpacity`. On a selected row the
/// square is `Fill.card`, so the symbol keeps its colour over the
/// selection fill.
struct InboxTile: View {
    let kind: InboxRowKind
    /// An owner artifact's folder icon; nil = the kind's own.
    var symbol: String?
    var size: CGFloat = IconSize.listTile
    var isSelected = false

    init(kind: InboxRowKind, symbol: String? = nil, size: CGFloat = IconSize.listTile, isSelected: Bool = false) {
        self.kind = kind
        self.symbol = symbol
        self.size = size
        self.isSelected = isSelected
    }

    var body: some View {
        let tint = Self.tint(kind)
        Image(systemName: symbol ?? Self.symbol(kind))
            .font(.body)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(
                isSelected ? Fill.card : tint.opacity(ChipTint.fillOpacity),
                in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .accessibilityHidden(true)
    }

    /// The kind's tint: the brief amber, waiting and approvals the warning
    /// tone, mail green, threads, Slack and artifacts the accent, ideas purple.
    static func tint(_ kind: InboxRowKind) -> Color {
        switch kind {
        case .brief: Tone.amber
        case .peopleWaiting, .approval: Tone.warning
        case .mailWaiting: Tone.success
        case .slackToday, .threads, .artifact: Color.accentColor
        case .ideas: Tone.status("purple")
        }
    }

    /// The kind's SF Symbol.
    static func symbol(_ kind: InboxRowKind) -> String {
        switch kind {
        case .brief: "sun.max"
        case .peopleWaiting: "person.2"
        case .mailWaiting: "envelope"
        case .slackToday: "number"
        case .threads: "bubble.left.and.bubble.right"
        case .ideas: "lightbulb"
        case .approval: "checkmark.seal"
        case .artifact: "folder"
        }
    }
}

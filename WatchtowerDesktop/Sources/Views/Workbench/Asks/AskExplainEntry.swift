import SwiftUI
import WatchtowerCore

/// **Not clear?** on one item of an ask (spec 2026-11-27 D1, D2): at the
/// foot of a question's block the labelled quiet control, trailing; on a
/// check step's text row a small quiet `?`. Either turns the drawer into the
/// chat about that item. Its accessibility label names the item; nothing for
/// a review ask or without a CLI (`AskExplainPresentation.showsEntry`).
struct AskExplainEntry: View {
    let item: AskExplainItem
    let kind: OwnerAskKind
    let hasCLI: Bool
    let action: () -> Void

    init(item: AskExplainItem, kind: OwnerAskKind, hasCLI: Bool, action: @escaping () -> Void) {
        self.item = item
        self.kind = kind
        self.hasCLI = hasCLI
        self.action = action
    }

    /// "Not clear? Question 2", "Not clear? Step 3".
    static func accessibilityLabel(_ item: AskExplainItem) -> String {
        AskExplainCopy.entryAccessibilityLabel(item)
    }

    var body: some View {
        if AskExplainPresentation.showsEntry(kind: kind, hasCLI: hasCLI) {
            if item.isStep {
                button { Image(systemName: "questionmark.circle").font(.caption) }
            } else {
                HStack {
                    Spacer(minLength: 0)
                    button { Label(AskExplainCopy.entry, systemImage: "questionmark.circle").font(.caption) }
                }
            }
        }
    }

    private func button(@ViewBuilder _ label: () -> some View) -> some View {
        Button(action: action, label: label)
            .buttonStyle(KitQuietButtonStyle(label: .secondary))
            .help(AskExplainCopy.entryHelp(for: item))
            .accessibilityLabel(Self.accessibilityLabel(item))
    }
}

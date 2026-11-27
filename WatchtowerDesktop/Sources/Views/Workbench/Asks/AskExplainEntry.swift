import SwiftUI
import WatchtowerCore

/// **Not clear?** on one item of an ask (spec 2026-11-27 D1, D2): at the
/// foot of a question's block the labelled quiet control, trailing; on a
/// check step's text row a small quiet `?`. Either turns the drawer into the
/// chat about that item. Its accessibility label names the item. The drawer
/// draws it only for a kind that shows entries, with a CLI
/// (`AskExplainPresentation.showsEntry`).
struct AskExplainEntry: View {
    let item: AskExplainItem
    let action: () -> Void

    /// "Not clear? Question 2", "Not clear? Step 3".
    static func accessibilityLabel(_ item: AskExplainItem) -> String {
        AskExplainCopy.entryAccessibilityLabel(item)
    }

    var body: some View {
        if item.isStep {
            button { Image(systemName: "questionmark.circle").font(.caption) }
        } else {
            HStack {
                Spacer(minLength: 0)
                button { Label(AskExplainCopy.entry, systemImage: "questionmark.circle").font(.caption) }
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

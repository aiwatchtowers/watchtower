import SwiftUI
import WatchtowerCore

/// **Not clear?** under an ask's options (spec 2026-11-24 "Where the control
/// is"): one quiet grey control, trailing, that turns the drawer into the
/// chat about the question. Nothing for a review ask or without a CLI
/// (`AskExplainPresentation.showsEntry`).
struct AskExplainEntry: View {
    let ask: OwnerAsk
    let hasCLI: Bool
    let action: () -> Void

    var body: some View {
        if AskExplainPresentation.showsEntry(kind: ask.kind, hasCLI: hasCLI) {
            HStack {
                Spacer(minLength: 0)
                Button(action: action) {
                    Label(AskExplainCopy.entry, systemImage: "questionmark.circle").font(.caption)
                }
                .buttonStyle(KitQuietButtonStyle(label: .secondary))
                .help(AskExplainCopy.entryHelp)
            }
        }
    }
}

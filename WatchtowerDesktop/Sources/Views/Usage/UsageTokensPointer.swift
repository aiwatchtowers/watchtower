import SwiftUI

/// "Tokens and cost: see the Watchtower tab" with a link to it: the run log
/// and the Progress tab no longer show `pipeline_runs` tokens, which miss
/// most calls; the ledger on Usage → Watchtower has them all. The caller
/// sets the font.
struct UsageTokensPointer: View {
    let buttonTitle: String
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: Spacing.regular) {
            Text("Tokens and cost: see the Watchtower tab")
                .foregroundStyle(.secondary)
            Button(buttonTitle, action: onOpen)
                .buttonStyle(.link)
        }
    }
}

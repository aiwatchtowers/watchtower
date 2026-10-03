import SwiftUI
import WatchtowerCore

/// Over the terminal of a session with open asks (spec 2026-10-03 Part 8):
/// the oldest one's title and how many more wait; Open shows it in the
/// drawer beside this terminal.
struct OwnerAskBanner: View {
    /// The session's open asks, oldest first; never empty.
    let asks: [OwnerAsk]
    let open: (OwnerAsk) -> Void

    var body: some View {
        if let first = asks.first {
            HStack(spacing: 8) {
                Image(systemName: OwnerAskPresentation.kindIcon(first.kind))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel(OwnerAskPresentation.kindLabel(first.kind))
                Text("Agent asks: \(first.title)")
                    .lineLimit(1)
                    .truncationMode(.tail)
                if asks.count > 1 {
                    Text("+\(asks.count - 1) more").foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Open") { open(first) }
                    .controlSize(.small)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.08))
        }
    }
}

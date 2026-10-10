import SwiftUI
import WatchtowerCore

/// The card over an `ask #N` hovered in a session's terminal (board #500):
/// the ask's kind icon and title, then "#N · kind · status"; a click on the
/// link opens the ask.
struct OwnerAskLinkCard: View {
    let ask: OwnerAsk

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: OwnerAskPresentation.askKindIcon(ask.kind))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(ask.title).font(.callout.weight(.medium)).lineLimit(2)
                Text(OwnerAskPresentation.linkCardDetail(ask)).font(.caption).foregroundStyle(.secondary)
                Text("Click to open").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: 320, alignment: .leading)
    }
}

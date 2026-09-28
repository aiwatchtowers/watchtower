import SwiftUI
import WatchtowerCore

/// A sources-panel group header: kind icon, name, count.
struct SourceGroupHeader: View {
    let group: ChatSourceGroup

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: SourcesSummaryRow.icon(group.kind)).font(.caption)
            Text(group.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text("\(group.sources.count)").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Title (≤2 lines), optional snippet (≤2 lines, secondary), date. Disabled
/// when the source has no resolvable link.
struct SourceItemRow: View {
    let source: ChatSource
    let link: URL?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let link { openURL(link) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(ChatSourceGrouping.displayTitle(source))
                        .font(.callout)
                        .foregroundStyle(link == nil ? Color.primary : Color.accentColor)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if link != nil {
                        Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let snippet = source.snippet {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                if let date = ChatSourceGrouping.displayDate(source.date) {
                    Text(date).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(link == nil)
        .help(link?.absoluteString ?? source.ref)
    }
}

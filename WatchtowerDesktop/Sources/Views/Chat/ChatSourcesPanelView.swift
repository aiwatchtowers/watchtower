import SwiftUI
import WatchtowerCore

/// The inspector's Sources panel: one answer's sources, deduplicated and
/// grouped (Slack channel / Jira project / space / Mail / Meetings / Other),
/// each group collapsible with its count.
///
/// An item opens its permalink/deep link through the app-wide allowed-scheme
/// `openURL`. Go emits a `url` only for kb hits with a `link` and
/// `list_messages` permalinks; `SourceLinkResolver` (pure, `WatchtowerCore`)
/// additionally turns a `jira:<KEY>` ref into `<site>/browse/<KEY>` given the
/// site URL read via `JiraConfigHelper.readSiteURL()`. Every other url-less
/// item is shown but not clickable — a documented v1 limitation.
struct ChatSourcesPanelView: View {
    let selection: ChatSourcesSelection
    var onClose: () -> Void
    @State private var collapsed: Set<String> = []
    @State private var jiraSiteURL: String?

    var body: some View {
        let groups = ChatSourceGrouping.groups(selection.sources)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "books.vertical")
                Text("Sources").font(.headline)
                Text("\(selection.sources.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close")
                    .accessibilityLabel("Close")
            }
            .padding(10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(groups) { group in
                        DisclosureGroup(isExpanded: expandedBinding(group.name)) {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(group.sources, id: \.dedupeKey) { source in
                                    SourceItemRow(source: source,
                                                  link: SourceLinkResolver.url(for: source, jiraSiteURL: jiraSiteURL))
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            SourceGroupHeader(group: group)
                        }
                    }
                }
                .padding(12)
            }
        }
        .task(id: selection.messageID) {
            if jiraSiteURL == nil { jiraSiteURL = JiraConfigHelper.readSiteURL() }
        }
    }

    private func expandedBinding(_ name: String) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(name) },
                set: { expanded in
                    if expanded { collapsed.remove(name) } else { collapsed.insert(name) }
                })
    }
}

private struct SourceGroupHeader: View {
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

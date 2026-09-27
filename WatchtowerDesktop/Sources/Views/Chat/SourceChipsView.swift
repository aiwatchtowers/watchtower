import SwiftUI
import WatchtowerCore

/// Onyx-style source chips (spec §3.2.3/§3.4), deduplicated; a chip opens its
/// permalink/deep link through the app-wide allowed-scheme `openURL`.
///
/// Preflight A12: Go emits a `url` only for kb hits with a `link` and
/// `list_messages` permalinks — every other read tool (`get_jira_issue`,
/// `list_jira_issues`, `get_transcript`, `get_person`, `get_digest`,
/// `get_target`, kb Jira/Gmail hits) carries only `ref`. Swift resolves the
/// one case it can: `SourceLinkResolver` (pure, `WatchtowerCore`, tested in
/// `SourceLinkResolverTests`) turns a `jira:<KEY>` ref into `<site>/browse/<KEY>`
/// given the site URL this view reads via `JiraConfigHelper.readSiteURL()`.
/// Every other url-less chip stays disabled — a documented v1 limitation.
struct SourceChipsView: View {
    let sources: [ChatSource]
    @Environment(\.openURL) private var openURL
    @State private var jiraSiteURL: String?

    var body: some View {
        let unique = ChatSource.dedupe(sources)
        if !unique.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(unique, id: \.dedupeKey) { source in
                    let link = SourceLinkResolver.url(for: source, jiraSiteURL: jiraSiteURL)
                    Button {
                        if let link { openURL(link) }
                    } label: {
                        Label(source.title.isEmpty ? source.ref : source.title, systemImage: Self.icon(source.kind))
                            .font(.caption)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .disabled(link == nil)
                    .help(link?.absoluteString ?? source.ref)
                }
            }
            .task {
                if jiraSiteURL == nil { jiraSiteURL = JiraConfigHelper.readSiteURL() }
            }
        }
    }

    static func icon(_ kind: String) -> String {
        switch kind {
        case "slack": "number"
        case "jira": "ticket"
        case "email": "envelope"
        case "meeting": "waveform"
        case "document": "doc.text"
        case "person": "person.crop.circle"
        default: "link"
        }
    }
}

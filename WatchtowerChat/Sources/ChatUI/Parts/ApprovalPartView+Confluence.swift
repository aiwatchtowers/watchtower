import SwiftUI
import WatchtowerDesign

/// `edit_confluence_page`: the page and how many passages change.
struct ConfluenceApproval: Equatable {
    static let tool = "edit_confluence_page"

    let title: String
    let url: URL?
    let changeCount: Int

    init?(_ payload: ChatApprovalPayload) {
        guard payload.tool == Self.tool else { return nil }
        let args = payload.args
        title = args["title"] as? String ?? ""
        url = (args["url"] as? String).flatMap(URL.init(string:)).flatMap { url in
            url.scheme?.lowercased() == "https" ? url : nil
        }
        changeCount = (args["changes"] as? [Any])?.count ?? 0
    }

    var changeLine: String { changeCount == 1 ? "1 change" : "\(changeCount) changes" }
}

struct ConfluenceApprovalBody: View {
    static let openLabel = "Open page"

    let edit: ConfluenceApproval
    let openURL: (URL) -> Void
    @Environment(\.chatUIStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(edit.title.isEmpty ? "Confluence page" : edit.title).font(.callout)
            Text(edit.changeLine).font(.caption).foregroundStyle(.secondary)
            if let url = edit.url {
                style.secondaryButton(Self.openLabel) { openURL(url) }
            }
        }
    }
}

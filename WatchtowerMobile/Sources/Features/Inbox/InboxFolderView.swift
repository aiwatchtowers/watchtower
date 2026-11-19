import SwiftUI
import WatchtowerInterface

/// One folder pushed from the root (mockups §1 Owner folder, §3 Needs approval, §6 Empty folder and Older cards):
/// its subfolders as flat rows, then its cards — under "In this folder" below subfolders, else under the phone's
/// Needs your decision / Today / Earlier when there is more than one group — and the line counting the cards that
/// stayed on the Mac. An owner folder with nothing in it says where its cards come from.
struct InboxFolderView: View {
    let center: InboxCenter
    let folderID: Int64
    let inputs: InboxInputs

    var body: some View {
        Group {
            if let feed = center.feed {
                content(feed)
            } else {
                Color.clear
            }
        }
        .navigationTitle(center.feed?.folders.first { $0.id == folderID }?.title ?? "")
        .navigationBarTitleDisplayMode(.large)
    }

    @ViewBuilder
    private func content(_ feed: Feed) -> some View {
        let model = InboxFolderModel(
            feed: feed, folderID: folderID, platform: .phone, hidden: center.hidden, now: inputs.now, grants: inputs.grants,
            blocksReadable: InboxCardDocument.readable
        )
        let subfolders = Self.children(of: folderID, in: InboxRootModel(feed: feed, platform: .phone).rows)
        if let empty = model.empty, subfolders.isEmpty {
            VStack(spacing: Spacing.regular) {
                Text(empty.title).font(TypeScale.screenTitle)
                Text(empty.body).font(TypeScale.rowTitle).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, Spacing.wide)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(subfolders, id: \.folder.id) { InboxFolderLink(row: $0) }
                    if !subfolders.isEmpty, !model.cards.isEmpty {
                        SectionHeader(InboxText.inThisFolder)
                    }
                    if subfolders.isEmpty, model.sections.count > 1 {
                        ForEach(model.sections, id: \.title) { section in
                            SectionHeader(section.title)
                            InboxCardList(center: center, cards: section.cards, inputs: inputs, showsPreview: true)
                        }
                    } else {
                        InboxCardList(center: center, cards: model.cards, inputs: inputs, showsPreview: true)
                    }
                    if let older = model.olderLine {
                        InboxFootnote(text: older)
                    }
                }
                .padding(.horizontal, Spacing.small)
                .padding(.bottom, Spacing.large)
            }
        }
    }

    /// The folder's own row in the root's tree, and so its subfolders (three levels drawn).
    static func children(of id: Int64, in rows: [InboxFolderRow]) -> [InboxFolderRow] {
        for row in rows {
            if row.folder.id == id { return row.children }
            let found = children(of: id, in: row.children)
            if !found.isEmpty { return found }
        }
        return []
    }
}

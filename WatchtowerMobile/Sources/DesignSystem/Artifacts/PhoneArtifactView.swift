import SwiftUI
import WatchtowerDesign

/// An Inbox card's blocks on the phone (mobile Inbox spec §7, mockups
/// §4–§5): the same Kit `ArtifactDocument` the Mac draws, from phone parts.
/// Flat rows with no separators; cards only for the detail blocks (metrics,
/// a table); colours only through `PhoneTone.artifact(_:)`. Every string it
/// draws is the document's. It pads itself with `RowInsets.flat`, for a
/// `ScrollView` page.
///
/// A row with a `ref` calls `onRef` (the host pushes its detail and owns its
/// native actions); a button calls `onAction` with its press address — the
/// card's own buttons, `cardActionCount` of them, come first. Web links open
/// in place.
struct PhoneArtifactView: View {
    let document: ArtifactDocument
    let cardActionCount: Int
    let onRef: (ArtifactRef) -> Void
    let onAction: (Int) -> Void

    init(
        document: ArtifactDocument,
        cardActionCount: Int = 0,
        onRef: @escaping (ArtifactRef) -> Void,
        onAction: @escaping (Int) -> Void
    ) {
        self.document = document
        self.cardActionCount = cardActionCount
        self.onRef = onRef
        self.onAction = onAction
    }

    var body: some View {
        let items = PhoneArtifactLayout.items(document, cardActionCount: cardActionCount)
        VStack(alignment: .leading, spacing: Spacing.small) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                PhoneArtifactItemView(item: item, onRef: onRef, onAction: onAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One drawn block.
struct PhoneArtifactItemView: View {
    let item: PhoneArtifactItem
    let onRef: (ArtifactRef) -> Void
    let onAction: (Int) -> Void

    var body: some View {
        switch item {
        case let .heading(text, level):
            PhoneArtifactHeading(text: text, level: level)
        case let .text(markdown):
            PhoneArtifactText(markdown: markdown)
        case let .metrics(metrics, columns):
            PhoneArtifactMetrics(metrics: metrics, columns: columns)
        case let .list(list):
            PhoneArtifactListView(list: list, onRef: onRef, onAction: onAction)
        case let .table(table, scrolls):
            PhoneArtifactTable(table: table, scrolls: scrolls)
        case let .person(person, initials, link):
            PhoneArtifactPerson(person: person, initials: initials, link: link)
        case let .link(title, subtitle, url):
            PhoneArtifactLink(title: title, subtitle: subtitle, url: url)
        case let .actions(buttons):
            PhoneArtifactButtons(buttons: buttons, onAction: onAction)
                .padding(.horizontal, RowInsets.flat.leading)
                .padding(.vertical, Spacing.small)
        }
    }
}

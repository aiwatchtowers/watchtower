import SwiftUI
import WatchtowerCore

/// "Contents" over a rendered document: its headings, indented by level; a
/// pick hands the heading's offset to `onPick` (a `DocumentScrollTarget`).
struct DocumentContentsMenu: View {
    let headings: [DocumentHeading]
    let onPick: (Int) -> Void

    var body: some View {
        let top = headings.map(\.level).min() ?? 1
        Menu {
            ForEach(Array(headings.enumerated()), id: \.offset) { _, heading in
                // Em spaces: a menu title keeps them, unlike leading plain spaces.
                let title = heading.title.isEmpty ? "(untitled heading)" : heading.title
                Button(String(repeating: "\u{2003}", count: heading.level - top) + title) { onPick(heading.offset) }
            }
        } label: {
            Label("Contents", systemImage: "list.bullet.indent")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(headings.isEmpty)
        .help(headings.isEmpty ? "This document has no headings" : "Jump to a heading")
    }
}

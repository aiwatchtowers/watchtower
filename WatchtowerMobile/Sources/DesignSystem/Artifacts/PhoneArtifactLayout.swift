import Foundation
import WatchtowerDesign

/// One button of a drawn card: an `actions` block's or a list row's, with
/// its press address (spec "Press address": the card's own buttons first,
/// then each block's in document order, `ArtifactDocument.flattenedActions`).
struct PhoneArtifactButton: Equatable {
    let label: String
    let kind: ArtifactActionKind
    let primary: Bool
    let index: Int
}

/// One row of a `list` block as the phone draws it.
struct PhoneArtifactRow: Equatable {
    /// What a tap on the row does: a row with a `ref` is the host's (its
    /// detail, its native actions); one without opens its web link.
    enum Press: Equatable {
        case ref(ArtifactRef)
        case link(URL)
        case none
    }

    let title: String
    let subtitle: String?
    let badge: ArtifactBadge?
    /// The leading dot; nil draws none.
    let tone: ArtifactTone?
    let press: Press
    let buttons: [PhoneArtifactButton]
}

struct PhoneArtifactList: Equatable {
    let title: String?
    let rows: [PhoneArtifactRow]
    /// Drawn when there are no rows.
    let empty: String
}

/// One drawn block, in document order (`PhoneArtifactLayout.items`).
enum PhoneArtifactItem: Equatable {
    case heading(text: String, level: Int)
    case text(markdown: String)
    case metrics([ArtifactMetric], columns: Int)
    case list(PhoneArtifactList)
    /// `scrolls`: wider than a phone's card (`PhoneArtifactLayout.tableScrolls`),
    /// so the table scrolls sideways inside it. The view also scrolls one the
    /// estimate let through whose content still does not fit.
    case table(ArtifactBlock.Table, scrolls: Bool)
    case person(ArtifactBlock.Person, initials: String, link: URL?)
    /// `subtitle` is the block's, else its URL text.
    case link(title: String, subtitle: String, url: URL?)
    case actions([PhoneArtifactButton])

    /// Every string the item draws, in reading order: a list row's title,
    /// its subtitle under it, its trailing badge, then its buttons.
    var texts: [String] {
        switch self {
        case let .heading(text, _): [text]
        case let .text(markdown): [markdown]
        case let .metrics(metrics, _): metrics.flatMap { [$0.value, $0.label] + [$0.hint].compactMap { $0 } }
        case let .list(list):
            [list.title].compactMap { $0 } + (list.rows.isEmpty ? [list.empty] : list.rows.flatMap { row in
                [row.title] + [row.subtitle, row.badge?.text].compactMap { $0 } + row.buttons.map(\.label)
            })
        case let .table(table, _):
            [table.title].compactMap { $0 } + table.columns.map(\.title) + table.rows.flatMap { $0.map(\.text) }
        case let .person(person, _, _): [person.name] + [person.role].compactMap { $0 } + person.lines.map(\.text)
        case let .link(title, subtitle, _): [title, subtitle]
        case let .actions(buttons): buttons.map(\.label)
        }
    }

    /// The item's buttons in press order.
    var buttons: [PhoneArtifactButton] {
        switch self {
        case let .list(list): list.rows.flatMap(\.buttons)
        case let .actions(buttons): buttons
        default: []
        }
    }
}

/// A block document as the phone draws it: one item per block, in order,
/// with each button's press address and each link checked. Pure, so the
/// order and the addresses are tested without drawing.
enum PhoneArtifactLayout {
    /// The most columns a table shows at a phone's width before it scrolls
    /// sideways (mockup §4: four columns scroll).
    static let fittingColumns = 3
    /// The text width a table card holds on the narrowest common iPhone
    /// (375 pt less the card's insets and padding), and the estimate of one
    /// character of the table's caption type.
    static let tableTextWidth: CGFloat = 315
    static let tableCharacterWidth: CGFloat = 7
    static let tableColumnSpacing: CGFloat = 12

    /// `cardActionCount`: the card's own buttons, which take the first
    /// press addresses (`ArtifactDocument.blockActionOffsets`).
    static func items(_ document: ArtifactDocument, cardActionCount: Int = 0) -> [PhoneArtifactItem] {
        let offsets = document.blockActionOffsets(cardActionCount: cardActionCount)
        return zip(document.blocks, offsets).map { block, start in item(block, start: start) }
    }

    private static func item(_ block: ArtifactBlock, start: Int) -> PhoneArtifactItem {
        switch block {
        case let .heading(text, level):
            return .heading(text: text, level: level)
        case let .text(markdown):
            return .text(markdown: markdown)
        case let .metrics(metrics):
            return .metrics(metrics, columns: metricColumns(metrics.count))
        case let .list(list):
            let rows = zip(list.rows, list.rowActionOffsets(start: start)).map { row, first in
                PhoneArtifactRow(
                    title: row.title, subtitle: row.subtitle, badge: row.badge, tone: row.tone,
                    press: row.ref.map(PhoneArtifactRow.Press.ref) ?? webURL(row.link).map(PhoneArtifactRow.Press.link) ?? .none,
                    buttons: buttons(row.actions, start: first)
                )
            }
            return .list(PhoneArtifactList(title: list.title, rows: rows, empty: list.empty))
        case let .table(table):
            return .table(table, scrolls: tableScrolls(table))
        case let .person(person):
            return .person(person, initials: initials(person.name), link: webURL(person.link))
        case let .link(title, url, subtitle):
            return .link(title: title, subtitle: subtitle ?? url, url: webURL(url))
        case let .actions(actions):
            return .actions(buttons(actions, start: start))
        }
    }

    private static func buttons(_ actions: [ArtifactAction], start: Int) -> [PhoneArtifactButton] {
        actions.enumerated().map { offset, action in
            PhoneArtifactButton(label: action.label, kind: action.kind, primary: action.primary, index: start + offset)
        }
    }

    /// A table scrolls sideways past `fittingColumns` columns, or when its
    /// widest cells (a header included) are estimated wider than the card:
    /// cells keep one line, so long text scrolls instead of truncating.
    static func tableScrolls(_ table: ArtifactBlock.Table) -> Bool {
        guard table.columns.count <= fittingColumns else { return true }
        let widths = table.columns.indices.map { column in
            ([table.columns[column].title] + table.rows.map { $0[column].text }).map(\.count).max() ?? 0
        }
        let estimate = CGFloat(widths.reduce(0, +)) * tableCharacterWidth
            + CGFloat(max(0, widths.count - 1)) * tableColumnSpacing
        return estimate > tableTextWidth
    }

    /// Metrics draw 2- or 3-up (mockup §4); four go 2 by 2.
    static func metricColumns(_ count: Int) -> Int {
        count == 4 ? 2 : max(1, min(count, 3))
    }

    /// "Colleague A" → "CA": the first letter of the first two words.
    static func initials(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    /// A link the phone opens (Safari, or the source's app through a
    /// universal link): http and https with a host only. The Mac's own
    /// `watchtower-nav://` and any other scheme draw as plain text.
    static func webURL(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host?.isEmpty == false else { return nil }
        return url
    }
}

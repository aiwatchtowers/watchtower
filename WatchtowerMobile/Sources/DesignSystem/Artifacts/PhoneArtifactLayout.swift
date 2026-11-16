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
    /// `scrolls`: too many columns for a phone's width, so the table scrolls
    /// sideways inside its card.
    case table(ArtifactBlock.Table, scrolls: Bool)
    case person(ArtifactBlock.Person, initials: String, link: URL?)
    /// `subtitle` is the block's, else its URL text.
    case link(title: String, subtitle: String, url: URL?)
    case actions([PhoneArtifactButton])

    /// Every string the item draws, top to bottom.
    var texts: [String] {
        switch self {
        case let .heading(text, _): [text]
        case let .text(markdown): [markdown]
        case let .metrics(metrics, _): metrics.flatMap { [$0.value, $0.label] + [$0.hint].compactMap { $0 } }
        case let .list(list):
            [list.title].compactMap { $0 } + (list.rows.isEmpty ? [list.empty] : list.rows.flatMap { row in
                [row.title] + [row.badge?.text, row.subtitle].compactMap { $0 } + row.buttons.map(\.label)
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
            return .table(table, scrolls: table.columns.count > fittingColumns)
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

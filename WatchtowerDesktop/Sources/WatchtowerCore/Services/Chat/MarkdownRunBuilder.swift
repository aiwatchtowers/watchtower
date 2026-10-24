import Foundation

/// A list item's marker, drawn on the item's first paragraph.
package enum MarkdownRunMarker: Hashable, Sendable {
    case bullet
    case number(Int)
    case checked
    case unchecked
}

/// One container a paragraph sits in, outermost first: a block quote (its
/// bar is one per quote, `id` unique within the run) or a list item.
package enum MarkdownRunLevel: Hashable, Sendable {
    case quote(id: Int)
    case listItem(MarkdownRunMarker)
}

/// One paragraph of a text run, with everything the app needs to style it
/// as `MarkdownBlockView` lays the same block out.
package struct MarkdownRunParagraph: Hashable, Sendable {
    package enum Kind: Hashable, Sendable {
        case body
        case heading(level: Int)
    }

    package let kind: Kind
    package let inlines: [MarkdownInline]
    package let levels: [MarkdownRunLevel]
    /// The first level that starts on this paragraph: the markers of the
    /// list items from here on are drawn on it. `levels.count` = none.
    package let startsAt: Int
    /// The gap above it: the spacing of the innermost stack that holds both
    /// it and the paragraph before (`blockSpacing` or `itemSpacing`); 0 for
    /// a run's first paragraph.
    package let spacingBefore: Double
}

/// A stretch of prose drawn by one native text view.
package struct MarkdownRun: Hashable, Sendable {
    package let paragraphs: [MarkdownRunParagraph]
}

package enum MarkdownSegment: Hashable, Sendable {
    /// `id`: the run's place among the message's segments.
    case textRun(MarkdownRun, id: Int)
    /// A block that keeps its own view: a code block, a table, a rule, or a
    /// list or quote holding one.
    case block(MarkdownBlock)
}

/// A finished chat answer's blocks → runs of prose (paragraphs, headings,
/// lists, block quotes) between the blocks that keep their own views (spec
/// 2026-10-24 §5b). Pure; memoised like `MarkdownDocument.parse`. The app
/// styles a run (`MarkdownRunText`) with the fonts, colours and spacing the
/// SwiftUI path (`MarkdownBlockView`) uses — the spacing constants below are
/// shared by both.
package enum MarkdownRunBuilder {
    /// Between the blocks of one stack (`MarkdownBlocksView`).
    package static let blockSpacing: Double = 8
    /// Between the items of one list (`MarkdownListView`).
    package static let itemSpacing: Double = 4

    private static let memo = MarkdownMemo<[MarkdownBlock], [MarkdownSegment]>(totalCostLimit: 1 << 16)

    package static func segments(_ blocks: [MarkdownBlock]) -> [MarkdownSegment] {
        memo.value(for: blocks, cost: { max($0.count, 1) }, build: { build(blocks) })
    }

    /// `segments` without the memo.
    package static func build(_ blocks: [MarkdownBlock]) -> [MarkdownSegment] {
        var segments: [MarkdownSegment] = []
        var emitter = Emitter()
        func flush() {
            guard !emitter.paragraphs.isEmpty else { return }
            segments.append(.textRun(MarkdownRun(paragraphs: emitter.paragraphs), id: segments.count))
            emitter = Emitter()
        }
        for block in blocks {
            if isProse(block) {
                if !emitter.paragraphs.isEmpty { emitter.pending = blockSpacing }
                emitter.emit(block, levels: [])
            } else {
                flush()
                segments.append(.block(block))
            }
        }
        flush()
        return segments
    }

    /// Whether `block` and everything in it is prose a run can hold.
    private static func isProse(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .heading, .paragraph: true
        case let .list(list): list.items.allSatisfy { $0.blocks.allSatisfy(isProse) }
        case let .quote(children): children.allSatisfy(isProse)
        case .code, .table, .rule: false
        }
    }

    private struct Emitter {
        var paragraphs: [MarkdownRunParagraph] = []
        var pending: Double = 0
        /// The outermost level started since the last paragraph.
        var started: Int?
        var nextQuoteID = 0

        mutating func emit(_ block: MarkdownBlock, levels: [MarkdownRunLevel]) {
            switch block {
            case let .heading(level, inlines): paragraph(.heading(level: level), inlines, levels)
            case let .paragraph(inlines): paragraph(.body, inlines, levels)
            case let .list(list):
                for (index, item) in list.items.enumerated() {
                    if index > 0 { pending = MarkdownRunBuilder.itemSpacing }
                    start(levels.count)
                    let inner = levels + [.listItem(marker(item, list: list, index: index))]
                    // An empty item still shows its marker.
                    if item.blocks.isEmpty { paragraph(.body, [], inner) }
                    stack(item.blocks, levels: inner)
                }
            case let .quote(children):
                start(levels.count)
                nextQuoteID += 1
                stack(children, levels: levels + [.quote(id: nextQuoteID)])
            case .code, .table, .rule:
                assertionFailure("not prose: \(block)")
            }
        }

        private mutating func stack(_ blocks: [MarkdownBlock], levels: [MarkdownRunLevel]) {
            for (index, child) in blocks.enumerated() {
                if index > 0 { pending = MarkdownRunBuilder.blockSpacing }
                emit(child, levels: levels)
            }
        }

        private mutating func start(_ level: Int) {
            started = min(started ?? level, level)
        }

        private mutating func paragraph(
            _ kind: MarkdownRunParagraph.Kind,
            _ inlines: [MarkdownInline],
            _ levels: [MarkdownRunLevel]
        ) {
            paragraphs.append(MarkdownRunParagraph(kind: kind, inlines: inlines, levels: levels,
                                                   startsAt: started ?? levels.count,
                                                   spacingBefore: paragraphs.isEmpty ? 0 : pending))
            pending = 0
            started = nil
        }

        private func marker(_ item: MarkdownListItem, list: MarkdownList, index: Int) -> MarkdownRunMarker {
            switch item.task {
            case .checked: .checked
            case .unchecked: .unchecked
            case .none: list.ordered ? .number(list.start + index) : .bullet
            }
        }
    }
}

/// A memo for pure renders keyed by a `Hashable` value, on `NSCache`
/// (evicts under memory pressure; `cost` bounds the total).
package final class MarkdownMemo<Key: Hashable, Value>: @unchecked Sendable {
    private final class Box: NSObject {
        let key: Key
        let hashCode: Int

        init(_ key: Key) {
            self.key = key
            hashCode = key.hashValue
        }

        override var hash: Int { hashCode }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? Box else { return false }
            return hashCode == other.hashCode && key == other.key
        }
    }

    private final class Entry {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private let cache = NSCache<Box, Entry>()

    package init(totalCostLimit: Int) {
        cache.totalCostLimit = totalCostLimit
    }

    package func value(for key: Key, cost: (Value) -> Int = { _ in 1 }, build: () -> Value) -> Value {
        let box = Box(key)
        if let hit = cache.object(forKey: box) { return hit.value }
        let value = build()
        cache.setObject(Entry(value), forKey: box, cost: cost(value))
        return value
    }
}

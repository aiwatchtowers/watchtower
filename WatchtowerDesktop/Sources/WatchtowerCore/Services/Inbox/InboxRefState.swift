import Foundation
import GRDB

/// A list row's record in an artifact (sub-project A's row `ref`): Core's
/// mirror of the Kit's `ArtifactRef`, so Core stays Kit-free; the app maps
/// between the two.
package struct InboxRef: Hashable, Sendable {
    /// The Kit's `ArtifactRefKind`, with the same raw values.
    package enum Kind: String, CaseIterable, Sendable {
        case inboxItem = "inbox_item"
        case track, idea, reminder, action
    }

    package let kind: Kind
    package let id: Int64

    package init(kind: Kind, id: Int64) {
        self.kind = kind
        self.id = id
    }

    /// Every list row's ref of a stored `blocks_json`, in document order: the
    /// Kit's `ArtifactDocument.refs` whenever the Kit reads the document
    /// (`InboxRefParityTests`). A document the Kit marks unreadable has none,
    /// so it counts as a plain artifact, for the cases checked here: not
    /// JSON, another version, no `blocks` array, a block that is not an
    /// object or has an unknown `type`, a list without `rows`, a row that is
    /// not an object or has no `title`, a malformed `ref`. Known gap: the
    /// other required fields of non-list blocks (a heading's `text`, a
    /// table's `columns` …) are not checked, so such a document still gives
    /// its list refs here while the Kit reads it as unreadable — pinned by
    /// `InboxRefParityTests.testKnownGapOtherBlockFieldsAreNotChecked`.
    package static func refs(blocksJSON: String) -> [Self] {
        guard !blocksJSON.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: Data(blocksJSON.utf8))) as? [String: Any],
              integer(object["v"]) == 1,
              let blocks = object["blocks"] as? [Any] else { return [] }
        var out: [Self] = []
        for block in blocks {
            guard let block = block as? [String: Any],
                  let type = block["type"] as? String, blockTypes.contains(type) else { return [] }
            guard type == "list" else { continue }
            guard let rows = block["rows"] as? [Any] else { return [] }
            for row in rows {
                guard let row = row as? [String: Any],
                      let title = row["title"] as? String, !title.isEmpty else { return [] }
                guard let value = row["ref"], !(value is NSNull) else { continue }
                guard let ref = value as? [String: Any],
                      let kind = (ref["kind"] as? String).flatMap(Kind.init(rawValue:)),
                      let id = integer(ref["id"]), id > 0 else { return [] }
                out.append(Self(kind: kind, id: id))
            }
        }
        return out
    }

    /// The block types the Kit's v1 decoder reads (`ArtifactJSON.block`).
    private static let blockTypes: Set<String> = [
        "heading", "text", "list", "table", "person", "metrics", "link", "actions"
    ]

    /// A JSON integer (never a bool or a fraction), as the Kit reads one.
    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number == NSNumber(value: number.int64Value) else { return nil }
        return number.int64Value
    }
}

/// The render-time check of row refs (spec "What 'open' means for a `ref`"):
/// a row is drawn only while its record is **shown** and counted only while
/// it **waits** on the owner, both read from the record in the same read as
/// the folder. A deleted record is neither.
package struct InboxRefState: Equatable, Sendable {
    package let shown: Set<InboxRef>
    package let waiting: Set<InboxRef>

    package init(shown: Set<InboxRef> = [], waiting: Set<InboxRef> = []) {
        self.shown = shown
        self.waiting = waiting
    }

    package func isShown(_ ref: InboxRef) -> Bool { shown.contains(ref) }
    package func waits(_ ref: InboxRef) -> Bool { waiting.contains(ref) }

}

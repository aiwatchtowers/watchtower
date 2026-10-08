import Foundation

/// The clipping rule every hub projection shares (mobile POC spec §4): a
/// capped text is cut at a grapheme boundary and ends in `…`, and the record
/// then carries `<field>_clipped: true`; a capped list carries
/// `<list>_more: <n not shown>`.
///
/// Caps count `Character`s (grapheme clusters), so a ZWJ emoji, a letter
/// with combining marks or an RTL cluster is kept or dropped whole. The flag
/// and the count are nil when nothing was cut, so the encoder omits the key.
enum SliceClip {
    static let ellipsis: Character = "…"

    /// `value` cut to at most `limit` graphemes, the ellipsis included.
    static func text(_ value: String, limit: Int) -> (text: String, clipped: Bool?) { // swiftlint:disable:this discouraged_optional_boolean
        guard value.count > limit else { return (value, nil) }
        guard limit > 0 else { return ("", true) }
        return (String(value.prefix(limit - 1)) + String(ellipsis), true)
    }

    /// The first `limit` items, and how many were left out.
    static func list<Element>(_ items: [Element], limit: Int) -> (items: [Element], more: Int?) {
        guard items.count > limit else { return (items, nil) }
        let kept = max(limit, 0)
        return (Array(items.prefix(kept)), items.count - kept)
    }
}

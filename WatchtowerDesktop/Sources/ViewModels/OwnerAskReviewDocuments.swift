import Foundation
import Observation
import WatchtowerCore

/// Review asks' snapshots rendered for the review body, once per ask: a
/// snapshot never changes (an edit is a new ask), and one may be 2 MiB, so
/// it is rendered off the main actor and kept, and the places in it (margin
/// comment anchors, focus items) are located once each — never per body
/// pass, where a keystroke in a margin comment would repeat them. Owned by
/// `OwnerAsksViewModel`; a few recent asks are kept.
@MainActor
@Observable
final class OwnerAskReviewDocuments {
    static let limit = 4

    /// Ask id → its rendered snapshot.
    private(set) var rendered: [Int64: RenderedDocument] = [:]
    /// Most recent last.
    @ObservationIgnored private var order: [Int64] = []
    @ObservationIgnored private var rendering: Set<Int64> = []
    /// Located places per ask; `NSNotFound` marks one not in the text.
    @ObservationIgnored private var anchorRanges: [Int64: [CommentAnchor: NSRange]] = [:]
    @ObservationIgnored private var focusRanges: [Int64: [OwnerAskFocus: NSRange]] = [:]

    /// Renders `ask`'s snapshot unless it already is (or is being).
    func prepare(_ ask: OwnerAsk) async {
        let id = ask.id
        if rendered[id] != nil {
            touch(id)
            return
        }
        guard !rendering.contains(id) else { return }
        rendering.insert(id)
        defer { rendering.remove(id) }
        let snapshot = ask.docSnapshot
        let doc = await Task.detached(priority: .userInitiated) { DocumentRendering.render(snapshot) }.value
        rendered[id] = doc
        touch(id)
    }

    func range(of anchor: CommentAnchor, askID: Int64) -> NSRange? {
        guard let doc = rendered[askID] else { return nil }
        if let known = anchorRanges[askID]?[anchor] { return known.location == NSNotFound ? nil : known }
        let found = OwnerAskReviewText.range(of: anchor, in: doc)
        anchorRanges[askID, default: [:]][anchor] = found ?? NSRange(location: NSNotFound, length: 0)
        return found
    }

    /// A comment just made on `range` needs no search.
    func remember(_ anchor: CommentAnchor, at range: NSRange, askID: Int64) {
        anchorRanges[askID, default: [:]][anchor] = range
    }

    func range(of focus: OwnerAskFocus, askID: Int64) -> NSRange? {
        guard let doc = rendered[askID] else { return nil }
        if let known = focusRanges[askID]?[focus] { return known.location == NSNotFound ? nil : known }
        let found = OwnerAskReviewText.range(of: focus, in: doc)
        focusRanges[askID, default: [:]][focus] = found ?? NSRange(location: NSNotFound, length: 0)
        return found
    }

    private func touch(_ id: Int64) {
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > Self.limit {
            let evicted = order.removeFirst()
            rendered[evicted] = nil
            anchorRanges[evicted] = nil
            focusRanges[evicted] = nil
        }
    }
}

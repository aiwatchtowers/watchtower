import Foundation

/// What `RecipeEditorView` tells the Monaco page, kept apart from the web
/// view so it can be tested: read-only first (so `show` leaves the keyboard
/// alone in a sheet), then the text — `show` the first time (and after a
/// page restart or a rebind to another buffer), `reload` (replace: an unsent
/// edit is sent on its old base and kept) after a `reset`.
@MainActor
package struct RecipeEditorPageState {
    package enum Command: Equatable {
        case setReadOnly(Bool)
        case show(id: String, path: String, text: String, rev: Int)
        case reload(id: String, text: String, rev: Int)
    }

    package private(set) var ready = false
    /// The buffer revision the page was last given; nil = nothing shown.
    private var toldRevision: Int?
    /// A fresh page is editable.
    private var toldReadOnly = false

    package init() {}

    /// The page model for a buffer.
    package static func modelID(_ buffer: RecipeBufferModel) -> String {
        "automation-\(buffer.automationID)"
    }

    /// The view was handed another buffer (or another file name) in the same
    /// place: the page must drop the old model and show the new one.
    package static func needsRebind(
        from old: RecipeBufferModel, path oldPath: String, to new: RecipeBufferModel, path newPath: String
    ) -> Bool {
        old !== new || oldPath != newPath
    }

    /// The page posted `ready`: it holds nothing yet.
    package mutating func pageReady() {
        ready = true
        toldRevision = nil
        toldReadOnly = false
    }

    /// The page is loading again (its process died): wait for `ready`.
    package mutating func pageLost() {
        ready = false
        toldRevision = nil
        toldReadOnly = false
    }

    /// The old model was closed: the next commands show the new buffer.
    package mutating func rebound() {
        toldRevision = nil
    }

    /// What to send now to bring the page up to `buffer` and `readOnly`.
    package mutating func commands(buffer: RecipeBufferModel, path: String, readOnly: Bool) -> [Command] {
        guard ready else { return [] }
        var out: [Command] = []
        if toldReadOnly != readOnly {
            out.append(.setReadOnly(readOnly))
            toldReadOnly = readOnly
        }
        guard toldRevision != buffer.revision else { return out }
        let id = Self.modelID(buffer)
        if toldRevision == nil {
            // The revision the text was typed on: an edit kept from an older
            // revision stays tied to that revision's file.
            out.append(.show(id: id, path: path, text: buffer.text, rev: buffer.textRevision))
        } else {
            out.append(.reload(id: id, text: buffer.text, rev: buffer.revision))
        }
        toldRevision = buffer.revision
        return out
    }
}

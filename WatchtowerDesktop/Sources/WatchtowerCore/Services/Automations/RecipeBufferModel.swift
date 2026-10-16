import Foundation
import Observation

/// The recipe text a `RecipeEditorView` shows and edits: the whole recipe
/// file (frontmatter, description and script), so a save from Monaco is
/// byte-lossless (R-P3-10). Owned by whoever shows the editor (the edit form
/// edits it, the confirmation sheet shows it read-only); the view never
/// touches the disk.
///
/// Revisions follow the Monaco page's protocol (`CodeEditorWeb/index.html`):
/// every `reset` is a new revision the page is given, and each edit the page
/// sends names the revision it was typed on (`base`). An edit typed before a
/// reset reached the page is kept, never dropped, and stays tied to the file
/// it was typed on: `baseContentHash` goes back to that revision's hash, so a
/// save passing it as `--expect-content-hash` is refused if the file moved on
/// instead of overwriting the newer file.
@MainActor
@Observable
package final class RecipeBufferModel {
    package let automationID: Int64
    /// The text as it is now, with the owner's edits.
    package private(set) var text: String
    /// The content hash of the file `text` was typed on.
    package private(set) var baseContentHash: String
    /// The revision the page is given with the text; bumped by every `reset`.
    package private(set) var revision = 1
    /// The revision `text` is tied to: `revision`, or an older one while an
    /// edit typed before a reset is kept. A page shown afresh is given this.
    package private(set) var textRevision = 1
    /// Why the editor page failed (load error, script error, a restart); nil
    /// while it works. Written by the view, shown by its host.
    package var pageError: String?

    package var isDirty: Bool { text != original }

    /// The text of the last load or reset.
    @ObservationIgnored private var original: String
    /// The content hash given with each revision.
    @ObservationIgnored private var hashes: [Int: String]

    package init(automationID: Int64, text: String, contentHash: String) {
        self.automationID = automationID
        self.text = text
        self.original = text
        self.baseContentHash = contentHash
        self.hashes = [1: contentHash]
    }

    /// The page sent the text as typed on revision `base`.
    package func pageSent(text: String, base: Int) {
        self.text = text
        if let hash = hashes[base] {
            baseContentHash = hash
            textRevision = base
        }
    }

    /// The host changed the text (the edit form spliced its fields into the
    /// frontmatter): a new revision the page is given, still unsaved and still
    /// tied to the file the text was typed on.
    package func replace(text newText: String) {
        revision += 1
        textRevision = revision
        hashes[revision] = baseContentHash
        text = newText
    }

    /// The file was loaded again (after a save, or a reload from disk): a new
    /// revision with nothing unsaved.
    package func reset(text: String, contentHash: String) {
        revision += 1
        textRevision = revision
        hashes[revision] = contentHash
        self.text = text
        original = text
        baseContentHash = contentHash
    }
}

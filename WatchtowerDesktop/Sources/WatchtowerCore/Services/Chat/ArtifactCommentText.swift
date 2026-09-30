import Foundation

/// The plain text an artifact's comments anchor on. A `document` renders its
/// markdown through `DocumentRendering` — the text the owner reads; every
/// other kind is its raw content (a table's CSV, an email body, code), shown
/// verbatim, `code` in the code-block style.
package enum ArtifactCommentText {
    package static func render(kind: String, content: String) -> RenderedDocument {
        switch kind {
        case "document":
            return DocumentRendering.render(content)
        case "code":
            let runs = content.isEmpty
                ? [] : [DocumentStyleRun(location: 0, length: content.utf16.count, style: .codeBlock)]
            return RenderedDocument(text: content, headings: [], runs: runs)
        default:
            return RenderedDocument(text: content, headings: [], runs: [])
        }
    }
}

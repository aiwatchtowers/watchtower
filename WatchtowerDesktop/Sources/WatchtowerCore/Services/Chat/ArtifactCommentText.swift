import Foundation

/// The text an artifact's comments anchor on, rendered the way the artifact
/// reads (the panel shows this one rendering whether or not the owner is
/// commenting): a `document` renders its markdown through
/// `DocumentRendering`, a `table` its CSV as a table, `code` one code block;
/// a draft message (email, Slack, event) is its raw content, shown verbatim
/// because that is exactly what would be sent.
package enum ArtifactCommentText {
    package static func render(kind: String, content: String) -> RenderedDocument {
        switch kind {
        case "document":
            return DocumentRendering.render(content)
        case "table":
            return DocumentRendering.renderTable(rows: CSVTable.parse(content))
        case "code":
            let runs = content.isEmpty
                ? [] : [DocumentStyleRun(location: 0, length: content.utf16.count, style: .codeBlock)]
            return RenderedDocument(text: content, headings: [], runs: runs)
        default:
            return RenderedDocument(text: content, headings: [], runs: [])
        }
    }
}

import Foundation

/// Print… (and the print panel's Save as PDF) and Export as Word for chat
/// artifacts: which artifacts offer them, and the print-friendly HTML page a
/// `document` artifact becomes. Pure; the App side prints the page in the
/// sandboxed web view (no network, CHAT-05) and turns it into a .docx.
///
/// The page is built from `MarkdownDocument`'s model, never from raw HTML:
/// raw HTML in the markdown is already plain text there, an image is a link,
/// every text is escaped and a link keeps its `href` only for http(s) and
/// mailto. So the page has nothing that loads — no `<img>`, `<script>`,
/// `<iframe>` or `url(...)` — which matters for the Word export, whose HTML
/// import has no content rules of its own.
package enum ArtifactPrint {
    /// A rendered page (`html`) or rendered markdown (`document`).
    package static func offersPrint(_ draft: ArtifactDraft) -> Bool {
        draft.kind == "document" || draft.kind == "html"
    }

    /// Only once the artifact is fully written and has something to print.
    package static func canPrint(_ draft: ArtifactDraft) -> Bool {
        offersPrint(draft) && hasContent(draft)
    }

    package static func offersWord(_ draft: ArtifactDraft) -> Bool {
        draft.kind == "document"
    }

    package static func canExportWord(_ draft: ArtifactDraft) -> Bool {
        offersWord(draft) && hasContent(draft)
    }

    package static func wordFileName(for draft: ArtifactDraft) -> String {
        "\(ArtifactParser.slug(draft.title)).docx"
    }

    /// What the print panel prints: the page itself for `html`, the
    /// rendered document for anything else. Nil when `canPrint` is false.
    package static func printPage(for draft: ArtifactDraft) -> String? {
        guard canPrint(draft) else { return nil }
        return draft.kind == "html" ? draft.content : documentPage(markdown: draft.content, title: draft.title)
    }

    /// A whole HTML page for a markdown document, with print-friendly CSS
    /// (no colours behind text, code wrapped, no page break inside a code
    /// block, table row or heading's first line).
    package static func documentPage(markdown: String, title: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>\(css)</style></head>
        <body>
        \(body(MarkdownDocument.parse(markdown)))
        </body></html>
        """
    }

    private static let css = """
    body{font-family:"Helvetica Neue",Helvetica,Arial,sans-serif;font-size:11pt;line-height:1.45;color:#000;margin:0}\
    h1{font-size:20pt}h2{font-size:16pt}h3{font-size:13pt}h4,h5,h6{font-size:11pt}\
    h1,h2,h3,h4,h5,h6{margin:1.1em 0 .4em;page-break-after:avoid;break-after:avoid}\
    p,ul,ol,blockquote,pre,table{margin:0 0 .7em}\
    code,pre{font-family:Menlo,Courier,monospace;font-size:9.5pt}\
    pre{white-space:pre-wrap;border:1px solid #bbb;padding:6pt;page-break-inside:avoid;break-inside:avoid}\
    blockquote{border-left:3px solid #999;margin-left:0;padding-left:10pt;color:#333}\
    table{border-collapse:collapse}th,td{border:1px solid #999;padding:3pt 6pt;vertical-align:top}\
    th{font-weight:bold}tr{page-break-inside:avoid;break-inside:avoid}\
    hr{border:0;border-top:1px solid #999}a{color:#000}
    """

    private static func hasContent(_ draft: ArtifactDraft) -> Bool {
        draft.isComplete && !draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Blocks

    static func body(_ blocks: [MarkdownBlock]) -> String {
        blocks.map(block).joined(separator: "\n")
    }

    private static func block(_ block: MarkdownBlock) -> String {
        switch block {
        case let .heading(level, inlines):
            let tag = "h\(min(max(level, 1), 6))"
            return "<\(tag)>\(inline(inlines))</\(tag)>"
        case let .paragraph(inlines):
            return "<p>\(inline(inlines))</p>"
        case let .code(_, code):
            return "<pre><code>\(escape(code))</code></pre>"
        case let .list(list):
            return self.list(list)
        case let .quote(children):
            return "<blockquote>\(body(children))</blockquote>"
        case let .table(table):
            return self.table(table)
        case .rule:
            return "<hr>"
        }
    }

    private static func list(_ list: MarkdownList) -> String {
        let tag = list.ordered ? "ol" : "ul"
        let start = list.ordered && list.start != 1 ? " start=\"\(list.start)\"" : ""
        let items = list.items.map { item -> String in
            let box = switch item.task {
            case .checked: "☑ "
            case .unchecked: "☐ "
            case .none: ""
            }
            // A tight item is one paragraph: no <p> margins inside the <li>.
            if case let .paragraph(inlines)? = item.blocks.first {
                return "<li>\(box)\(inline(inlines))\(body(Array(item.blocks.dropFirst())))</li>"
            }
            return "<li>\(box)\(body(item.blocks))</li>"
        }
        return "<\(tag)\(start)>\(items.joined())</\(tag)>"
    }

    private static func table(_ table: MarkdownTable) -> String {
        func align(_ column: Int) -> String {
            guard column < table.alignments.count else { return "" }
            switch table.alignments[column] {
            case .leading: return ""
            case .center: return " style=\"text-align:center\""
            case .trailing: return " style=\"text-align:right\""
            }
        }
        func row(_ cells: [[MarkdownInline]], tag: String) -> String {
            "<tr>" + cells.enumerated().map { "<\(tag)\(align($0.offset))>\(inline($0.element))</\(tag)>" }.joined() + "</tr>"
        }
        return "<table><thead>\(row(table.header, tag: "th"))</thead><tbody>"
            + table.rows.map { row($0, tag: "td") }.joined() + "</tbody></table>"
    }

    // MARK: Inlines

    private static func inline(_ inlines: [MarkdownInline]) -> String {
        inlines.map(inline).joined()
    }

    private static func inline(_ inline: MarkdownInline) -> String {
        switch inline {
        case let .text(value): escape(value)
        case let .code(value): "<code>\(escape(value))</code>"
        case let .emphasis(children): "<em>\(self.inline(children))</em>"
        case let .strong(children): "<strong>\(self.inline(children))</strong>"
        case let .strikethrough(children): "<s>\(self.inline(children))</s>"
        case let .link(destination, children): link(destination, children)
        case .lineBreak: "<br>"
        case .softBreak: "\n"
        }
    }

    /// The text alone when the target is not http(s)/mailto, or when the
    /// link has no text (an image without alt text): then its address.
    private static func link(_ destination: String, _ children: [MarkdownInline]) -> String {
        let text = children.isEmpty ? escape(destination) : inline(children)
        guard let scheme = URL(string: destination)?.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return text }
        return "<a href=\"\(escape(destination))\">\(text)</a>"
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(character)
            }
        }
        return out
    }
}

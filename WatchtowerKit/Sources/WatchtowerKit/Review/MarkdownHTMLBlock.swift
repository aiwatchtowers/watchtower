import Foundation

/// The start of a CommonMark HTML block (spec 0.31, §4.6) and how it ends.
/// Conditions 1–5 end at their closing marker, 6 and 7 at a blank line;
/// only condition 7 (any other complete tag alone on its line) cannot
/// interrupt a paragraph, so an inline `<placeholder>` stays paragraph text.
enum MarkdownHTMLBlock: Equatable {
    /// Ends at the first line, this one included, that holds the marker
    /// (matched without case).
    case closing(String)
    /// Ends before the next blank line.
    case blankLine(interruptsParagraph: Bool)

    var interruptsParagraph: Bool {
        if case let .blankLine(interrupts) = self { return interrupts }
        return true
    }

    func ends(_ line: String) -> Bool {
        if case let .closing(marker) = self { return line.lowercased().contains(marker) }
        return false
    }

    private static let rawTags = ["script", "pre", "style", "textarea"]

    private static let blockTags: Set<String> = [
        "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col",
        "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure",
        "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr",
        "html", "iframe", "legend", "li", "link", "main", "menu", "menuitem", "nav", "noframes", "ol",
        "optgroup", "option", "p", "param", "search", "section", "summary", "table", "tbody", "td", "tfoot",
        "th", "thead", "title", "tr", "track", "ul"
    ]

    /// A complete open or closing tag, alone on the line.
    private static let completeTag: NSRegularExpression? = {
        let attribute = #"\s+[A-Za-z_:][A-Za-z0-9_.:-]*(?:\s*=\s*(?:[^\s"'=<>`]+|'[^']*'|"[^"]*"))?"#
        let open = #"<[A-Za-z][A-Za-z0-9-]*(?:"# + attribute + #")*\s*/?>"#
        let close = #"</[A-Za-z][A-Za-z0-9-]*\s*>"#
        return try? NSRegularExpression(pattern: "^(?:\(open)|\(close))\\s*$")
    }()

    init?(_ line: String) {
        guard MarkdownLine.indent(line) < 4 else { return nil }
        let rest = String(line.drop { $0 == " " })
        guard rest.hasPrefix("<") else { return nil }
        let lower = rest.lowercased()
        if let tag = Self.rawTags.first(where: { Self.startsTag(lower.dropFirst(), named: $0, closing: ">") }) {
            self = .closing("</\(tag)>")
        } else if lower.hasPrefix("<!--") {
            self = .closing("-->")
        } else if lower.hasPrefix("<?") {
            self = .closing("?>")
        } else if lower.hasPrefix("<![cdata[") {
            self = .closing("]]>")
        } else if lower.hasPrefix("<!"), lower.dropFirst(2).first?.isLetter == true {
            self = .closing(">")
        } else if Self.startsBlockTag(lower) {
            self = .blankLine(interruptsParagraph: true)
        } else if Self.isCompleteTag(rest) {
            self = .blankLine(interruptsParagraph: false)
        } else {
            return nil
        }
    }

    /// `<div`, `</div`, … followed by a space, the end, `>` or `/>`.
    private static func startsBlockTag(_ lower: String) -> Bool {
        let name = lower.dropFirst(lower.hasPrefix("</") ? 2 : 1)
        return blockTags.contains { startsTag(name, named: $0, closing: ">", selfClosing: true) }
    }

    private static func startsTag(_ text: Substring, named name: String, closing: String, selfClosing: Bool = false) -> Bool {
        guard text.hasPrefix(name) else { return false }
        let after = text.dropFirst(name.count)
        guard let next = after.first else { return true }
        return next == " " || after.hasPrefix(closing) || (selfClosing && after.hasPrefix("/>"))
    }

    private static func isCompleteTag(_ text: String) -> Bool {
        guard let completeTag else { return false }
        return completeTag.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

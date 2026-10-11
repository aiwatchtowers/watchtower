import UIKit
import WatchtowerKit

/// Styles a review snapshot for reading (design pass spec §3 bug 7):
/// headings by level, body text with 6 pt paragraph spacing, list lines
/// with a hanging indent the width of their marker. The string is exactly
/// `document.text`, because comment anchors are UTF-16 offsets into it; only
/// attributes change. Fonts follow Dynamic Type. Known limit: inline
/// emphasis and code blocks stay plain, because `PlainTextDocument` does not
/// mark them.
enum ReviewDocumentStyler {
    static let paragraphSpacing: CGFloat = 6

    static func attributed(_ document: PlainTextDocument, traits: UITraitCollection? = nil) -> NSAttributedString {
        let text = document.text as NSString
        let body = bodyFont(traits: traits)
        let styled = NSMutableAttributedString(string: document.text, attributes: [
            .font: body, .foregroundColor: UIColor.label, .paragraphStyle: paragraph(headIndent: 0)
        ])
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byParagraphs) { line, range, _, _ in
            guard let line, let prefix = listPrefix(of: line) else { return }
            let indent = (prefix as NSString).size(withAttributes: [.font: body]).width
            styled.addAttribute(.paragraphStyle, value: paragraph(headIndent: indent), range: range)
        }
        for heading in document.headings where heading.offset < text.length {
            let rest = NSRange(location: heading.offset, length: text.length - heading.offset)
            let newline = text.range(of: "\n", options: [], range: rest)
            let end = newline.location == NSNotFound ? text.length : newline.location
            let range = NSRange(location: heading.offset, length: end - heading.offset)
            styled.addAttribute(.font, value: headingFont(level: heading.level, traits: traits), range: range)
        }
        return styled
    }

    /// The text view shows `shown`, styled at `styledCategory`. It restyles
    /// when the document changed (a newer round) or the Dynamic Type size
    /// did: the attributed fonts do not follow a size change by themselves.
    static func needsRestyle(
        shown: String,
        styledCategory: UIContentSizeCategory?,
        document: PlainTextDocument,
        category: UIContentSizeCategory
    ) -> Bool {
        shown != document.text || styledCategory != category
    }

    /// The marker a list line starts with, its leading spaces included:
    /// "• ", "N. ", "☐ " or "☑ "; nil for any other line.
    static func listPrefix(of line: String) -> String? {
        let indent = String(line.prefix { $0 == " " })
        let rest = line.dropFirst(indent.count)
        if let marker = ["• ", "☐ ", "☑ "].first(where: { rest.hasPrefix($0) }) {
            return indent + marker
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return indent + digits + ". "
    }

    static func bodyFont(traits: UITraitCollection?) -> UIFont {
        UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
    }

    /// Level 1 `.title2` semibold, level 2 `.title3` semibold, deeper
    /// `.headline`.
    static func headingFont(level: Int, traits: UITraitCollection?) -> UIFont {
        switch level {
        case 1: scaled(.title2, weight: .semibold, traits: traits)
        case 2: scaled(.title3, weight: .semibold, traits: traits)
        default: UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traits)
        }
    }

    /// A weighted system font at `style`'s default size, scaled by
    /// `UIFontMetrics` for Dynamic Type.
    private static func scaled(_ style: UIFont.TextStyle, weight: UIFont.Weight, traits: UITraitCollection?) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        return UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: base.pointSize, weight: weight), compatibleWith: traits)
    }

    private static func paragraph(headIndent: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = paragraphSpacing
        style.headIndent = headIndent
        return style
    }
}

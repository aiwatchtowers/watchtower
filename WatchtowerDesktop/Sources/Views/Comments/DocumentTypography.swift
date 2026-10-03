import AppKit
import WatchtowerCore

/// The sizes and rhythm `DocumentAttributedString` lays a rendered document
/// out with. `.standard` is the comment views' layout (the font's own line
/// height, no paragraph spacing); `ReviewTypography.style` the owner-ask
/// review body's.
struct DocumentTypography: Equatable {
    var bodySize: CGFloat = 14
    var codeSize: CGFloat = 13
    /// Heading levels 1, 2 and 3; deeper headings take the body size.
    var headingSizes: [CGFloat] = [22, 18, 16]
    /// Line heights and paragraph spacing for every paragraph; nil leaves
    /// paragraphs without a style of their own.
    var rhythm: Rhythm?

    static let standard = Self()

    var bodyFont: NSFont { .systemFont(ofSize: bodySize) }
    var codeFont: NSFont { .monospacedSystemFont(ofSize: codeSize, weight: .regular) }

    func headingSize(_ level: Int) -> CGFloat {
        (1...headingSizes.count).contains(level) ? headingSizes[level - 1] : bodySize
    }

    /// What a paragraph is, as far as its spacing goes.
    enum Role: Equatable {
        case body, heading(Int), code, listItem, tableCell, rule
    }

    struct Gap: Equatable {
        let before: CGFloat
        let after: CGFloat
    }

    struct Rhythm: Equatable {
        /// Line heights as a multiple of the font size (CSS `line-height`).
        var lineHeight: CGFloat
        var headingLineHeight: CGFloat
        var codeLineHeight: CGFloat
        /// Space below a body paragraph, and between list items.
        var paragraphSpacing: CGFloat
        var listSpacing: CGFloat
        /// Around headings of level 1, 2 and 3; deeper ones take the last.
        var headingGaps: [Gap]
        /// The size of the blank line every block ends with.
        var blankLineSize: CGFloat
    }

    /// Applies `rhythm` to paragraph styles, its line heights resolved
    /// against the fonts once per build.
    struct Styler {
        private let rhythm: Rhythm
        private let body: CGFloat
        private let code: CGFloat
        private let headings: [CGFloat]

        init(_ type: DocumentTypography, rhythm: Rhythm) {
            self.rhythm = rhythm
            let metrics = NSLayoutManager()
            // `lineHeightMultiple` scales the font's own line height.
            let multiple = { (factor: CGFloat, font: NSFont) in
                factor * font.pointSize / metrics.defaultLineHeight(for: font)
            }
            body = multiple(rhythm.lineHeight, type.bodyFont)
            code = multiple(rhythm.codeLineHeight, type.codeFont)
            headings = (1...max(type.headingSizes.count, 1)).map {
                multiple(rhythm.headingLineHeight, .systemFont(ofSize: type.headingSize($0), weight: .bold))
            }
        }

        func apply(_ role: Role, to style: NSMutableParagraphStyle) {
            switch role {
            case .body:
                style.lineHeightMultiple = body
                style.paragraphSpacing = rhythm.paragraphSpacing
            case let .heading(level):
                let index = min(max(level, 1), headings.count) - 1
                let gap = rhythm.headingGaps.isEmpty
                    ? Gap(before: 0, after: 0) : rhythm.headingGaps[min(level, rhythm.headingGaps.count) - 1]
                style.lineHeightMultiple = headings[index]
                style.paragraphSpacingBefore = gap.before
                style.paragraphSpacing = gap.after
            case .code:
                style.lineHeightMultiple = code
                style.paragraphSpacing = 0
            case .listItem:
                style.lineHeightMultiple = body
                style.paragraphSpacing = rhythm.listSpacing
            case .tableCell:
                style.lineHeightMultiple = body
            case .rule:
                break
            }
        }
    }
}

/// The owner-ask review body's reading layout (spec 2026-10-03 Part 8): a
/// centered column of at most 680 pt, body 14 pt at 1.55 line height,
/// headings 22/17/15 pt with more space above than below. Lists hang, code
/// blocks are tinted boxes and tables `NSTextTable`s, as in every document
/// view; inline code keeps the body's line height, so a wrapped code span
/// never stretches its line. `DocumentTextView` shows it with
/// `horizontalInset(forWidth:)`.
enum ReviewTypography {
    static let columnWidth: CGFloat = 680

    static let style = DocumentTypography(
        bodySize: 14,
        codeSize: 13,
        headingSizes: [22, 17, 15],
        rhythm: .init(
            lineHeight: 1.55,
            headingLineHeight: 1.25,
            codeLineHeight: 1.4,
            paragraphSpacing: 8,
            listSpacing: 4,
            headingGaps: [.init(before: 22, after: 8), .init(before: 18, after: 6), .init(before: 14, after: 4)],
            blankLineSize: 4
        )
    )

    /// The text inset that centers a column of at most `columnWidth` in a
    /// view `width` points wide.
    static func horizontalInset(forWidth width: CGFloat) -> CGFloat {
        max(ReadableColumn.minInset, ((width - columnWidth) / 2).rounded(.down))
    }
}

#if os(macOS)
import SwiftUI

/// A question card's question, option description and read-only "Other" answer on the Mac: the Markdown view (blocks,
/// and links whose scheme `AllowedURLSchemes` refuses stripped), as the app's card drew them.
struct QuestionMarkdown: View {
    let text: String
    var lineBreaks = false

    var body: some View {
        MarkdownView(text: text, lineBreaks: lineBreaks)
    }
}

extension QuestionPartView {
    /// An option's label without its markup.
    static func optionLabel(_ text: String) -> AttributedString { MarkdownView.inlineLabel(text) }
}
#endif

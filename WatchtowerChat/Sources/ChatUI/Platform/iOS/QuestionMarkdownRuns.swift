#if os(iOS)
import SwiftUI

/// A question card's question, option description and read-only "Other" answer on the phone: inline Markdown.
struct QuestionMarkdown: View {
    let text: String
    var lineBreaks = false

    var body: some View {
        Text(QuestionPartView.inline(text))
    }
}

extension QuestionPartView {
    /// An option's label without its markup.
    static func optionLabel(_ text: String) -> AttributedString { inline(text) }

    /// The phone reads an option's "Recommended" mark with its label, as VoiceOver combined them before.
    static var readsRecommended: Bool { true }
}
#endif

import Foundation

/// A screen the help answer may link to.
package struct HelpScreen: Sendable {
    package let rawValue: String
    package let title: String

    package init(rawValue: String, title: String) {
        self.rawValue = rawValue
        self.title = title
    }
}

package enum HelpPrompt {
    package static func system(catalog: String) -> String {
        """
        You answer questions about how to use the Watchtower Mac app. \
        Answer only from the guide sections given with each question. \
        If they don't cover it, say the guide doesn't cover it and suggest asking in AI Chat. \
        Start with one line that answers, then numbered steps if there are steps. \
        Use screen and button names exactly as the app shows them. \
        To link a screen write a markdown link to watchtower-nav://<screen> using only the screens listed with the question. \
        Never invent features, settings or shortcuts.

        Guide contents:
        \(catalog)
        """
    }

    /// Formats one turn. Retrieval (question + previous question) is the caller's job.
    package static func turn(
        question: String,
        previousQuestion: String?,
        currentPage: String,
        screens: [HelpScreen],
        sections: [GuideSection]
    ) -> String {
        var lines = ["Current page: \(currentPage)"]
        lines.append("Screens: " + screens.map { "\($0.rawValue)=\($0.title)" }.joined(separator: ", "))
        if sections.isEmpty {
            lines.append("Guide sections: none matched")
        } else {
            lines.append("Guide sections:")
            for s in sections {
                lines.append("### \(s.pageTitle) › \(s.heading)\n\(s.text)")
            }
        }
        lines.append("Question: \(question)")
        return lines.joined(separator: "\n")
    }
}

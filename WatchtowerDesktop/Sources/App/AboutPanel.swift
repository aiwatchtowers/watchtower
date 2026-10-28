import AppKit
import WatchtowerCore

/// The standard About panel with links to the GitHub repository and to the
/// release notes of the running version (ask #694: every build flavor).
enum AboutPanel {
    static func show() {
        ActivationPolicyDecision.becomeRegularAndActivate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits()])
    }

    static func credits() -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style
        ]
        let text = NSMutableAttributedString()
        func link(_ title: String, _ url: URL) {
            var attributes = base
            attributes[.link] = url
            text.append(NSAttributedString(string: title, attributes: attributes))
        }
        link("GitHub repository", ReleaseLinks.repository)
        text.append(NSAttributedString(string: "  ·  ", attributes: base))
        link("Release notes for \(Constants.appVersion)", ReleaseLinks.notes(version: Constants.appVersion))
        return text
    }
}

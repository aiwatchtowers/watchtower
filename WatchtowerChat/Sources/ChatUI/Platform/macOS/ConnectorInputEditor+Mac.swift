#if os(macOS)
import AppKit
import ChatWire
import SwiftUI
import WatchtowerDesign

/// Monospaced editor for a connector call's input; Approve stays disabled while the text is not a JSON object
/// (`ConnectorCallProposal.approval`).
struct ConnectorInputEditor: View {
    @Binding var text: String
    let approval: ConnectorCallProposal.Approval?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            PlainJSONEditor(text: $text)
                .frame(minHeight: 80, maxHeight: 260)
                .padding(Spacing.small)
                .background(ApprovalEditorChrome.background, in: RoundedRectangle(cornerRadius: Radius.control))
                .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(ApprovalEditorChrome.stroke))
                .accessibilityIdentifier("agentAction.connectorEditor")
            ConnectorInputNote(approval: approval)
        }
    }
}

/// The approval card's editor chrome on the Mac: the text background, the workspace pick as radio rows, link buttons.
enum ApprovalEditorChrome {
    static var background: Color { Color(nsColor: .textBackgroundColor) }
    static var stroke: Color { Color.secondary.opacity(strokeOpacity) }
    private static let strokeOpacity = 0.3
}

extension View {
    func slackWorkspacePickerStyle() -> some View { pickerStyle(.radioGroup) }
    func approvalLinkStyle() -> some View { buttonStyle(.link) }
}

/// A monospaced plain-text editor with every macOS substitution off: a smart quote would break the JSON (Approve
/// disabled for no visible reason) and a smart dash inside a string would silently change what is sent.
private struct PlainJSONEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.string = text
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.isEditable = context.environment.isEnabled
        if textView.string != text { textView.string = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainJSONEditor

        init(_ parent: PlainJSONEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
#endif

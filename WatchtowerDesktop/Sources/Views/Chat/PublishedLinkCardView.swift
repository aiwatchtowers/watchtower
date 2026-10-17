import AppKit
import SwiftUI
import WatchtowerCore

/// "Published on claude.ai": the page or doc the assistant published to the
/// owner's own account (spec 2026-10-16-chat-claude-ai-tools-design §3.1).
/// Its two buttons open the link in the browser or copy it — nothing else
/// (CHAT-05).
struct PublishedLinkCardView: View {
    let link: PublishedLink
    /// The last action's outcome ("Copied", or why nothing happened).
    @State private var notice: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.title3)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(link.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(notice ?? "Published on claude.ai")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            ForEach(Array(link.actions.enumerated()), id: \.offset) { _, action in
                Button(Self.label(action)) { run(action) }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(.separatorColor).opacity(0.5)))
        .help(link.url.absoluteString)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Published on claude.ai: \(link.title)")
    }

    private func run(_ action: PublishedLinkAction) {
        let done = PublishedLinkActionPerformer.perform(action)
        switch action {
        case .open: notice = done ? nil : "Couldn't open the link — use Copy Link"
        case .copy: notice = done ? "Link copied" : "Couldn't copy the link"
        }
    }

    private static func label(_ action: PublishedLinkAction) -> String {
        switch action {
        case .open: "Open in Browser"
        case .copy: "Copy Link"
        }
    }
}

/// The only place a `PublishedLinkAction` becomes an effect: opening a
/// claude.ai page in the browser or a pasteboard write. Nothing here sends
/// (CHAT-05).
enum PublishedLinkActionPerformer {
    /// Whether the page opened or the link was copied.
    static func perform(
        _ action: PublishedLinkAction,
        pasteboard: NSPasteboard = .general,
        open: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> Bool {
        switch action {
        case .open(let url):
            // Re-checked here: an action is a plain value, not proof of a
            // permitted link.
            guard PublishedLink.permits(url) else { return false }
            return open(url)
        case .copy(let text):
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        }
    }
}

import SwiftUI
import WatchtowerCore

/// A message card in the Inbox reading pane (spec C1 §6.2): who, where, the
/// text, why it matters and the thread, then **Open in Slack/Mail/Jira/Linear**
/// (only with a permalink), **Discuss in Chat**, **Hand to Agent…**, **Done**
/// (resolve), **Hide** (dismiss) and **Snooze ▾**. A channel item that folded
/// several messages (INBOX-09) lists each with its sender and own link. The
/// text is someone else's: plain `Text`, never markdown, and fenced as data
/// in the chat and agent hand-off (`InboxCardSubject(message:)`).
struct InboxMessagePane: View {
    let row: HomeFeedInboxRow
    var isWriting = false
    let onDone: () -> Void
    let onHide: () -> Void
    /// A Snooze choice's duration: "1d", "3d" or "1w".
    let onSnooze: (String) -> Void
    let onCommand: (InboxCardCommand) -> Void
    var workbenches: [Workbench] = []
    /// The screens a `watchtower-nav://` link may open.
    var navScreens: Set<String> = []
    /// The moment the source line's time is told from.
    var now = Date()

    /// Snooze ▾'s choices and their `watchtower inbox snooze` durations (R5).
    static let snoozeChoices: [(label: String, duration: String)] = [
        ("Tomorrow", "1d"), ("In 3 days", "3d"), ("Next week", "1w")
    ]

    var body: some View {
        let item = row.item
        VStack(alignment: .leading, spacing: Spacing.medium) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                Text(InboxListRow.messageSource(row, now: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if item.priority == "high" {
                    Chip(text: "High", color: Tone.priority("high"))
                }
            }
            if item.isAccumulated {
                Text(item.mentionCountTitle)
                    .font(.title3.weight(.semibold))
                mentions(item)
            } else if !item.snippet.isEmpty {
                plain(item.snippet)
            }
            if !item.whyMatters.isEmpty {
                block("Why it matters", item.whyMatters)
            }
            if !item.threadDigest.isEmpty {
                block("Thread", item.threadDigest)
            }
            InboxCommonRow(
                subject: InboxCardSubject(message: row),
                link: Self.link(item.permalink),
                openLabel: Self.openLabel(item.triggerType),
                navScreens: navScreens,
                workbenches: workbenches,
                isWriting: isWriting,
                onCommand: onCommand
            ) {
                Button("Done", action: onDone)
                Button("Hide", action: onHide)
                Menu("Snooze") {
                    ForEach(Self.snoozeChoices, id: \.duration) { choice in
                        Button(choice.label) { onSnooze(choice.duration) }
                    }
                }
                .menuStyle(.button)
                .fixedSize()
            }
            .padding(.top, Spacing.small)
        }
    }

    /// "Open in Jira", "Open in Linear", "Open in Mail", else "Open in Slack".
    static func openLabel(_ trigger: String) -> String {
        if trigger.hasPrefix("jira_") { return "Open in Jira" }
        if trigger.hasPrefix("linear_") { return "Open in Linear" }
        if trigger == "email_received" { return "Open in Mail" }
        return "Open in Slack"
    }

    /// A stored permalink; none, no button.
    static func link(_ permalink: String) -> URL? {
        permalink.isEmpty ? nil : URL(string: permalink)
    }

    /// "Ann: text"; the bare text when the sender has no name (a raw id would
    /// read as noise).
    static func mentionLine(_ mention: InboxItem.Mention, senderNames: [String: String]) -> String {
        guard let name = senderNames[mention.sender], !name.isEmpty else { return mention.text }
        return "\(name): \(mention.text)"
    }

    private func mentions(_ item: InboxItem) -> some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            if item.mentionsEarlier > 0 {
                Text("+\(item.mentionsEarlier) earlier")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(item.mentionList, id: \.ts) { mention in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                    plain(Self.mentionLine(mention, senderNames: row.senderNames))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let link = mention.permalink.flatMap(Self.link) {
                        Button("Open") { onCommand(.openLink(link)) }
                            .buttonStyle(.kitQuiet)
                            .controlSize(.small)
                            .disabled(!InboxCardLinkPolicy.permits(link, navScreens: navScreens))
                            .help(link.absoluteString)
                    }
                }
            }
        }
        .padding(Spacing.medium)
        .card()
    }

    private func block(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            plain(text)
        }
    }

    /// Someone else's words as plain text: `Text(verbatim:)` parses no
    /// markdown, so a Slack link in it is never a live link.
    private func plain(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

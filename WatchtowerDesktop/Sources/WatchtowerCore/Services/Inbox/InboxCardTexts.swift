import Foundation

/// The words of an automation's Inbox card: the list row's preview and
/// source line, the reading pane's source line, and the default texts of the
/// common row's Discuss in Chat and Hand to Agent… (spec B1, B2).
package enum InboxCardTexts {
    /// The list row's preview: at most this many characters, "…" included.
    package static let previewLimit = 140
    /// Go's `workbench target add` cap in Unicode scalars, as Go counts
    /// runes (the app's `WorkbenchNewTargetRequest.titleLimit`).
    package static let targetTitleLimit = 200

    /// The body as one line of plain text: the markdown parsed by the chat's
    /// `MarkdownDocument`, its text joined, whitespace collapsed, clipped.
    package static func preview(_ markdown: String) -> String {
        let plain = MarkdownDocument.parse(markdown).map(text).joined(separator: " ")
        let words = plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard words.count > previewLimit else { return words }
        return words.prefix(previewLimit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The list row's source: "<automation> · 10:00" today, else its day.
    package static func sourceLine(_ card: AutomationOutputCard, now: Date, calendar: Calendar = .current) -> String {
        stamped(card.automationName, at: card.createdAt, now: now, calendar: calendar)
    }

    /// A list row's source: "<prefix> · 10:00" today, else "<prefix> · Oct 18"
    /// (a reminder's due time, a proposal's creation).
    package static func stamped(_ prefix: String, at date: Date, now: Date, calendar: Calendar = .current) -> String {
        let sameDay = calendar.isDate(date, inSameDayAs: now)
        return "\(prefix) · \(format(date, sameDay ? "HH:mm" : "MMM d", calendar))"
    }

    /// The reading pane's source, which opens the run.
    package static func readingSourceLine(_ card: AutomationOutputCard, calendar: Calendar = .current) -> String {
        "ϟ \(card.automationName) · run #\(card.runID) · \(format(card.createdAt, "MMM d, HH:mm", calendar))"
    }

    /// Discuss in Chat's first message, put in the composer and not sent;
    /// the card itself goes along as `attachmentMarkdown`.
    package static func discussMessage(_ card: AutomationOutputCard) -> String {
        "Let's discuss the Inbox card \"\(card.title)\" from \(card.automationName):\n\n\(card.body)"
    }

    /// Hand to Agent…'s task: the title first (the target's title), then the
    /// body and where the card came from.
    package static func handToAgentTask(_ card: AutomationOutputCard) -> String {
        var parts = [card.title, card.body]
        if !card.link.isEmpty { parts.append("Source: \(card.link)") }
        parts.append("From the Inbox card of the automation \(card.automationName), run #\(card.runID).")
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The card as a chat attachment.
    package static func attachmentMarkdown(_ card: AutomationOutputCard) -> String {
        var parts = ["# \(card.title)", "ϟ \(card.automationName) · run #\(card.runID)"]
        if !card.link.isEmpty { parts.append("Source: \(card.link)") }
        if !card.body.isEmpty { parts.append(card.body) }
        return parts.joined(separator: "\n\n")
    }

    /// A target title from a task: its first non-empty line, trimmed and
    /// clipped to `targetTitleLimit` scalars.
    package static func targetTitle(fromTask task: String) -> String {
        let line = task.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: line.unicodeScalars.prefix(targetTitleLimit))
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    private static func format(_ date: Date, _ pattern: String, _ calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    // MARK: - Plain text of parsed markdown

    private static func text(_ block: MarkdownBlock) -> String {
        switch block {
        case let .heading(_, inlines), let .paragraph(inlines): text(inlines)
        case let .code(_, code): code
        case let .list(list): list.items.flatMap(\.blocks).map(text).joined(separator: " ")
        case let .quote(blocks): blocks.map(text).joined(separator: " ")
        case let .table(table): (table.header + table.rows.flatMap { $0 }).map(text).joined(separator: " ")
        case .rule: ""
        }
    }

    private static func text(_ inlines: [MarkdownInline]) -> String {
        inlines.map(text).joined()
    }

    private static func text(_ inline: MarkdownInline) -> String {
        switch inline {
        case let .text(value), let .code(value): value
        case let .emphasis(children), let .strong(children), let .strikethrough(children),
             let .link(_, children): text(children)
        case .lineBreak, .softBreak: " "
        }
    }
}

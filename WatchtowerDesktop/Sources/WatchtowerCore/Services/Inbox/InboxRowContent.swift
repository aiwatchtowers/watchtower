import Foundation

/// What a row of the Inbox list stands for (spec "The list"): it picks the
/// row's tile and its tint.
package enum InboxRowKind: Equatable, Sendable {
    case brief, peopleWaiting, mailWaiting, slackToday, threads, ideas, approval, artifact
}

/// The count on the right of a row: what is new or waits, in a tone.
package struct InboxRowPill: Equatable, Sendable {
    package enum Tone: Equatable, Sendable {
        /// Waits on the owner (people today, rows that wait, approvals).
        case needsYou
        /// Something new to look at (unread tracks).
        case news
        /// A batch to go through (ideas to judge); also the neutral tone of a
        /// count that never waits on the owner (Mail waiting's mail today).
        case batch
    }

    package let count: Int
    package let tone: Tone

    package init(count: Int, tone: Tone) {
        self.count = count
        self.tone = tone
    }
}

/// One row of the Inbox list as plain values: the first real line of its
/// content, the line under it, the time on the right and the count.
package struct InboxRowContent: Equatable, Sendable {
    package let kind: InboxRowKind
    package let title: String
    /// The first real line ("Colleague B in a DM: “…”"); empty draws none.
    package let preview: String
    /// The line under it ("3 older", "Your automation · run #4"); empty draws none.
    package let meta: String
    /// `InboxRowTime.label`; empty draws none.
    package let time: String
    package let pill: InboxRowPill?
    package let isUnread: Bool
    /// An owner artifact's folder icon; nil = the kind's own.
    package let symbol: String?

    package init(
        kind: InboxRowKind,
        title: String,
        preview: String = "",
        meta: String = "",
        time: String = "",
        pill: InboxRowPill? = nil,
        isUnread: Bool = false,
        symbol: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.preview = preview
        self.meta = meta
        self.time = time
        self.pill = pill
        self.isUnread = isUnread
        self.symbol = symbol
    }
}

/// A row's time on the right.
package enum InboxRowTime {
    /// The same day `HH:mm`; the day before "yesterday"; 2–6 days back the
    /// weekday ("Mon"); older this year "3 Nov"; another year "3 Nov 2025".
    /// In `calendar`'s zone, `en_US_POSIX`. A future date reads as today.
    package static func label(_ date: Date, now: Date, calendar: Calendar) -> String {
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        let format: String
        switch days {
        case ...0: format = "HH:mm"
        case 1: return "yesterday"
        case 2...6: format = "EEE"
        default:
            format = calendar.component(.year, from: date) == calendar.component(.year, from: now)
                ? "d MMM" : "d MMM yyyy"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

/// A row's preview from a markdown body.
package enum InboxRowText {
    /// The longest preview, "…" included.
    package static let previewLimit = 240

    /// The body's non-empty lines without their leading markdown markers
    /// (`#`, `>`, `-`, `*`, `+`, `1.`) and without `**`, `__` and `` ` ``,
    /// joined by a space, whitespace collapsed, capped at `previewLimit`
    /// characters with "…".
    package static func preview(_ body: String) -> String {
        let lines = body.components(separatedBy: .newlines).map { line in
            stripMarkers(line)
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "")
        }
        let text = lines.joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard text.count > previewLimit else { return text }
        return String(text.prefix(previewLimit - 1)) + "…"
    }

    /// `line` without its leading markers: a heading's `#`s, a quote's `>`,
    /// a list's `-`, `*`, `+` or `1.` (a list marker or a heading only
    /// before a space, as markdown reads them).
    private static func stripMarkers(_ line: String) -> String {
        var rest = Substring(line).drop(while: \.isWhitespace)
        while let first = rest.first {
            var marker = 0
            if first == ">" {
                marker = 1
            } else if first == "#" {
                marker = rest.prefix { $0 == "#" }.count
            } else if "-*+".contains(first) {
                marker = 1
            } else if first.isNumber {
                let digits = rest.prefix(while: \.isNumber).count
                if rest.dropFirst(digits).first == "." { marker = digits + 1 }
            }
            guard marker > 0 else { break }
            let after = rest.dropFirst(marker)
            // A quote's `>` needs no space; the others do (or end the line).
            guard first == ">" || after.isEmpty || after.first?.isWhitespace == true else { break }
            rest = after.drop(while: \.isWhitespace)
        }
        return String(rest)
    }
}

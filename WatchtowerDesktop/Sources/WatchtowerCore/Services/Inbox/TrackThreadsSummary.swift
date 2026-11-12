import Foundation

/// Why a Track my threads row has news: the spec's four chips, in precedence order.
package enum TrackNewsReason: Equatable {
    case replyToYou, decision, mention, attachment

    package var label: String {
        switch self {
        case .replyToYou: "reply to you"
        case .decision: "decision"
        case .mention: "mention"
        case .attachment: "attachment"
        }
    }
}

/// Track my threads, as the Inbox row and its pane show it: the active
/// tracks split by `TrackNewsRule` into the news (listed) and the quiet
/// (folded), plus the row and pane copy.
package struct TrackThreadsSummary: Equatable {
    /// Active tracks with news, newest last event first (then track id desc).
    package let news: [InboxTrackCard]
    /// Active tracks without news.
    package let quietCount: Int
    /// Quiet tracks whose last event is older than `TrackNewsRule.quietDays`.
    package let quietOverLimitCount: Int

    package static let visibleNewsLimit = 5

    /// `tracks` are the active (not dismissed) tracks.
    package static func build(tracks: [InboxTrackCard], now: Date) -> Self {
        let news = tracks
            .filter { TrackNewsRule.hasNews(track: $0, now: now) }
            .sorted { lhs, rhs in
                lhs.lastEventAt != rhs.lastEventAt
                    ? lhs.lastEventAt > rhs.lastEventAt
                    : lhs.track.id > rhs.track.id
            }
        return Self(
            news: news,
            quietCount: tracks.count - news.count,
            quietOverLimitCount: tracks.filter { TrackNewsRule.isQuiet(track: $0, now: now) }.count
        )
    }

    // MARK: - Per track

    /// The newest event's summary, else the newest source ref as
    /// `<author>: “<text>”`, else the first non-empty line of the context.
    package static func latestLine(_ card: InboxTrackCard) -> String {
        if !card.latestEventSummary.isEmpty { return card.latestEventSummary }
        if let ref = newestRef(card.track) {
            return "\(ref.author): “\(ref.text)”"
        }
        return card.track.context
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }

    package static func reason(_ card: InboxTrackCard) -> TrackNewsReason? {
        let track = card.track
        if !track.ballOn.isEmpty, track.ballOn == track.assigneeUserID { return .replyToYou }
        if track.category == "decision" || track.category == "decision_needed" || !track.decisionSummary.isEmpty {
            return .decision
        }
        let rawAssignee = track.assigneeUserID.split(separator: ":").last.map(String.init) ?? ""
        if !rawAssignee.isEmpty, let ref = newestRef(track), mentions(ref.text, userID: rawAssignee) {
            return .mention
        }
        if card.newestRefHasAttachment { return .attachment }
        return nil
    }

    package static func newCountText(_ card: InboxTrackCard) -> String? {
        card.newEventCount > 0 ? "\(card.newEventCount) new" : nil
    }

    // MARK: - Copy

    /// The first two news rows as `<track>: <latest line>`; no news → the
    /// "Nothing new" line; no active tracks → "".
    package var rowPreview: String {
        if news.isEmpty {
            return quietCount > 0 ? "Nothing new in \(Self.threads(quietCount))" : ""
        }
        let lines = news.prefix(2).map { card in
            let line = Self.latestLine(card)
            return line.isEmpty ? card.track.text : "\(card.track.text): \(line)"
        }
        return lines.joined(separator: "\n")
    }

    package var rowMeta: String {
        switch quietCount {
        case 0: ""
        case 1: "1 quiet thread folded"
        default: "\(quietCount) quiet threads folded"
        }
    }

    package var pillCount: Int? { news.isEmpty ? nil : news.count }

    package var isUnread: Bool { !news.isEmpty }

    package var paneSubtitle: String {
        "\(Self.threads(news.count)) with news for you · \(quietCount) quiet · scanned after every sync"
    }

    package var quietNote: String? {
        guard quietCount > 0 else { return nil }
        let first = quietCount == 1
            ? "1 thread has nothing new for you."
            : "\(quietCount) threads have nothing new for you."
        guard quietOverLimitCount > 0 else { return first }
        let verb = quietOverLimitCount == 1 ? "has" : "have"
        return "\(first) \(quietOverLimitCount) of them \(verb) been quiet for over \(TrackNewsRule.quietDays) days."
    }

    package var showsStopQuiet: Bool { quietOverLimitCount > 0 }

    // MARK: - Helpers

    private static func threads(_ count: Int) -> String {
        count == 1 ? "1 thread" : "\(count) threads"
    }

    /// The source ref with the highest `ts` (the same pick as `TrackQueries`).
    private static func newestRef(_ track: Track) -> TrackSourceRef? {
        track.decodedSourceRefs.max { (Double($0.ts) ?? 0) < (Double($1.ts) ?? 0) }
    }

    /// Slack mention markup for `userID`: `<@U1>` or `<@U1|name>`.
    private static func mentions(_ text: String, userID: String) -> Bool {
        text.contains("<@\(userID)>") || text.contains("<@\(userID)|")
    }
}

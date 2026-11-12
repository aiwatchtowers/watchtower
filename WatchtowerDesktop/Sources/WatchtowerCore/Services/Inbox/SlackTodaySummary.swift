import Foundation
import os

/// Slack today's numbers for its list row and reading pane (inbox redesign
/// phase 5), read from the built-in's state: the `"today"` value the recipe
/// `internal/automations/builtin/recipes/slack-today.md` writes, v 1 (Go
/// golden `internal/automations/builtin/testdata/slack_today_state.json`).
/// A channel entry is a news channel `{name, n, more, lines, link?}`, a
/// more-only one `{name, n, more, link}` or `{name, n, more, lines: []}`, or
/// a quiet one `{name, n}`; the channels the state folded away are counted
/// in `quiet_rest` and `more_rest`. "Channel" here is any conversation the
/// built-in reads: channels, 1:1 DMs and group DMs (ask #653).
package struct SlackTodaySummary: Equatable, Sendable {
    /// One of the day's lines, under its channel's name.
    package struct Line: Equatable, Sendable {
        package let channel: String
        package let text: String

        package init(channel: String, text: String) {
            self.channel = channel
            self.text = text
        }
    }

    /// A channel with messages but nothing for the owner.
    package struct QuietChannel: Equatable, Sendable {
        package let name: String
        package let messages: Int

        package init(name: String, messages: Int) {
            self.name = name
            self.messages = messages
        }
    }

    /// The state's local date, `yyyy-MM-dd`.
    package let day: String
    package let messages: Int
    /// Channels with any message: the entries plus the folded quiet and
    /// more-only ones. Approximate on extreme days: a channel folded twice
    /// counts twice (the recipe's v1 limit).
    package let channels: Int
    /// Channels with at least one line or lines taken out (`more > 0`),
    /// the folded more-only ones included.
    package let newsChannels: Int
    /// At most two lines, label rank first (asks you, needs someone,
    /// decided, fyi), then the newest.
    package let topLines: [Line]
    /// The quiet entries, busiest first, then by name.
    package let quiet: [QuietChannel]
    /// Quiet channels the state folded (`quiet_rest`): no names kept.
    package let quietRestChannels: Int
    package let quietRestMessages: Int

    package init(
        day: String,
        messages: Int,
        channels: Int,
        newsChannels: Int,
        topLines: [Line],
        quiet: [QuietChannel],
        quietRestChannels: Int = 0,
        quietRestMessages: Int = 0
    ) {
        self.day = day
        self.messages = messages
        self.channels = channels
        self.newsChannels = newsChannels
        self.topLines = topLines
        self.quiet = quiet
        self.quietRestChannels = quietRestChannels
        self.quietRestMessages = quietRestMessages
    }

    /// The state is for `now`'s local date in `calendar`'s zone.
    package func isToday(now: Date, calendar: Calendar) -> Bool {
        day == HomeFeedBuilder.dayString(now, calendar: calendar)
    }

    /// A channel's name as drawn: `#name` for a channel; a 1:1 DM (`@name`)
    /// and a group DM (its members' names, so with a space) as they are.
    /// Twin of the recipe's `heading`.
    package static func heading(_ name: String) -> String {
        name.hasPrefix("@") || name.contains(" ") ? name : "#\(name)"
    }

    /// "N conversations with nothing for you · M messages", the folded
    /// ones counted; nil when no conversation is quiet.
    package var quietLine: String? {
        let count = quiet.count + quietRestChannels
        guard count > 0 else { return nil }
        let messages = quiet.reduce(0) { $0 + $1.messages } + quietRestMessages
        return "\(Self.plural(count, "conversation", "conversations")) with nothing for you · "
            + Self.plural(messages, "message", "messages")
    }

    /// The open fold's last row, "and N more conversations", for the quiet
    /// conversations the state keeps no name of; nil when there are none.
    package var quietMoreLine: String? {
        quietRestChannels > 0 ? "and \(Self.plural(quietRestChannels, "more conversation", "more conversations"))" : nil
    }

    /// "1 message", "900 messages".
    package static func plural(_ count: Int, _ one: String, _ many: String) -> String {
        "\(count) \(count == 1 ? one : many)"
    }

    // MARK: - Decoding

    fileprivate init(_ today: TodayJSON) {
        var lines: [(rank: Int, at: Date, line: Line)] = []
        var quiet: [QuietChannel] = []
        var news = 0
        for channel in today.channels.values {
            let channelLines = channel.lines ?? []
            if channelLines.isEmpty, (channel.more ?? 0) == 0 {
                quiet.append(QuietChannel(name: channel.name, messages: channel.count))
                continue
            }
            news += 1
            for line in channelLines {
                lines.append((Self.rank[line.label] ?? -1, AutomationDates.parse(line.time) ?? .distantPast,
                              Line(channel: channel.name, text: line.text)))
            }
        }
        let quietRest = today.quietRest ?? QuietRestJSON(channels: 0, messages: 0)
        let moreRest = today.moreRest?.channels ?? 0
        self.init(
            day: today.day,
            messages: today.messages,
            channels: today.channels.count + quietRest.channels + moreRest,
            newsChannels: news + moreRest,
            topLines: Array(lines.sorted(by: Self.lineOrder).prefix(2).map(\.line)),
            quiet: quiet.sorted { $0.messages != $1.messages ? $0.messages > $1.messages : $0.name < $1.name },
            quietRestChannels: quietRest.channels,
            quietRestMessages: quietRest.messages
        )
    }

    /// The card's order of lines (the recipe's `lineOrder`): label rank,
    /// then the newest, then by channel and text so the order is stable.
    private static func lineOrder(
        _ lhs: (rank: Int, at: Date, line: Line), _ rhs: (rank: Int, at: Date, line: Line)
    ) -> Bool {
        if lhs.rank != rhs.rank { return lhs.rank > rhs.rank }
        if lhs.at != rhs.at { return lhs.at > rhs.at }
        if lhs.line.channel != rhs.line.channel { return lhs.line.channel < rhs.line.channel }
        return lhs.line.text < rhs.line.text
    }

    /// The recipe's `RANK`: what the card shows first.
    private static let rank = ["fyi": 0, "decided": 1, "needs_someone": 2, "asks_you": 3]

    /// `automation_state.state_json`: its `"today"`, decoded in one pass.
    fileprivate struct StateJSON: Decodable {
        let today: TodayJSON?
    }

    /// The `"today"` value; its `v` is read first, so another version is
    /// refused before the rest of its shape is looked at.
    fileprivate struct TodayJSON: Decodable {
        let day: String
        let messages: Int
        let channels: [String: ChannelJSON]
        let quietRest: QuietRestJSON?
        let moreRest: MoreRestJSON?

        enum CodingKeys: String, CodingKey {
            case version = "v", day, messages, channels, quietRest = "quiet_rest", moreRest = "more_rest"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let version = try container.decode(Int.self, forKey: .version)
            guard version == 1 else { throw SlackTodayState.UnsupportedVersion(version: version) }
            day = try container.decode(String.self, forKey: .day)
            messages = try container.decode(Int.self, forKey: .messages)
            channels = try container.decode([String: ChannelJSON].self, forKey: .channels)
            quietRest = try container.decodeIfPresent(QuietRestJSON.self, forKey: .quietRest)
            moreRest = try container.decodeIfPresent(MoreRestJSON.self, forKey: .moreRest)
        }
    }

    fileprivate struct ChannelJSON: Decodable {
        let name: String
        let count: Int
        let more: Int?
        let lines: [LineJSON]?

        enum CodingKeys: String, CodingKey { case name, count = "n", more, lines }
    }

    fileprivate struct LineJSON: Decodable {
        let label: String
        let text: String
        let time: String

        enum CodingKeys: String, CodingKey { case label, text, time = "at" }
    }

    fileprivate struct QuietRestJSON: Decodable {
        let channels: Int
        let messages: Int
    }

    fileprivate struct MoreRestJSON: Decodable {
        let channels: Int
    }
}

/// Slack today's state as the Inbox reads it: none yet, today's summary
/// (`read`, which may be another day's), or a `"today"` this version cannot
/// read — another `v`, or a value that does not decode. Unreadable is never
/// folded into none: the row and pane say the numbers can't be read.
package enum SlackTodayState: Equatable, Sendable {
    /// No state, or a state without `"today"`.
    case none
    case read(SlackTodaySummary)
    /// A state this version cannot read.
    case unreadable

    /// The summary when read; nil when none or unreadable.
    package var summary: SlackTodaySummary? {
        if case let .read(summary) = self { return summary }
        return nil
    }

    /// The state of `automation_state.state_json`, decoded once. An
    /// unreadable state is logged once per content (its reason and coding
    /// path keys only, never its text).
    package static func decode(stateJSON: String) -> Self {
        do {
            let state = try JSONDecoder().decode(SlackTodaySummary.StateJSON.self, from: Data(stateJSON.utf8))
            guard let today = state.today else { return .none }
            return .read(SlackTodaySummary(today))
        } catch {
            logOnce(stateJSON, error)
            return .unreadable
        }
    }

    /// `"today"`'s `v` is not 1.
    struct UnsupportedVersion: Error {
        let version: Int
    }

    private static let log = Logger(subsystem: "com.watchtower.desktop", category: "slack-today")
    /// The contents already logged in this process (their hashes).
    private static let logged = OSAllocatedUnfairLock<Set<Int>>(initialState: [])

    private static func logOnce(_ stateJSON: String, _ error: Error) {
        let isNew = logged.withLock { $0.insert(stateJSON.hashValue).inserted }
        guard isNew else { return }
        switch error {
        case let unsupported as UnsupportedVersion:
            log.error("slack-today state unreadable: version \(unsupported.version, privacy: .public)")
        case let DecodingError.dataCorrupted(context), let DecodingError.keyNotFound(_, context),
             let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            log.error("slack-today state unreadable: decode failed at \(path, privacy: .private)")
        default:
            log.error("slack-today state unreadable: decode failed")
        }
    }
}

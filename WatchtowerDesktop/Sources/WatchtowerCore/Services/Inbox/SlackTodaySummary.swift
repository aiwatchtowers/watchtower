import Foundation

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
    /// Channels with any message: the entries plus the folded quiet ones.
    /// Approximate on extreme days: a channel folded twice counts twice
    /// (the recipe's v1 limit).
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

    /// The summary of `automation_state.state_json`; nil when it has no
    /// `"today"`, its `v` is not 1, or it cannot be decoded.
    package static func decode(stateJSON: String) -> Self? {
        let data = Data(stateJSON.utf8)
        let decoder = JSONDecoder()
        guard let version = try? decoder.decode(StateJSON<VersionJSON>.self, from: data).today?.version, version == 1,
              let today = try? decoder.decode(StateJSON<TodayJSON>.self, from: data).today else { return nil }
        return Self(today)
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

    /// "N channels with nothing for you · M messages", the folded ones
    /// counted; nil when no channel is quiet.
    package var quietLine: String? {
        let count = quiet.count + quietRestChannels
        guard count > 0 else { return nil }
        let messages = quiet.reduce(0) { $0 + $1.messages } + quietRestMessages
        return "\(Self.plural(count, "channel", "channels")) with nothing for you · "
            + Self.plural(messages, "message", "messages")
    }

    /// The open fold's last row, "and N more channels", for the quiet
    /// channels the state keeps no name of; nil when there are none.
    package var quietMoreLine: String? {
        quietRestChannels > 0 ? "and \(Self.plural(quietRestChannels, "more channel", "more channels"))" : nil
    }

    /// "1 message", "900 messages".
    package static func plural(_ count: Int, _ one: String, _ many: String) -> String {
        "\(count) \(count == 1 ? one : many)"
    }

    // MARK: - Decoding

    private init(_ today: TodayJSON) {
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
        self.init(
            day: today.day,
            messages: today.messages,
            channels: today.channels.count + quietRest.channels,
            newsChannels: news + (today.moreRest?.channels ?? 0),
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

    private struct StateJSON<Today: Decodable>: Decodable {
        let today: Today?
    }

    private struct VersionJSON: Decodable {
        let version: Int

        enum CodingKeys: String, CodingKey { case version = "v" }
    }

    private struct TodayJSON: Decodable {
        let day: String
        let messages: Int
        let channels: [String: ChannelJSON]
        let quietRest: QuietRestJSON?
        let moreRest: MoreRestJSON?

        enum CodingKeys: String, CodingKey {
            case day, messages, channels, quietRest = "quiet_rest", moreRest = "more_rest"
        }
    }

    private struct ChannelJSON: Decodable {
        let name: String
        let count: Int
        let more: Int?
        let lines: [LineJSON]?

        enum CodingKeys: String, CodingKey { case name, count = "n", more, lines }
    }

    private struct LineJSON: Decodable {
        let label: String
        let text: String
        let time: String

        enum CodingKeys: String, CodingKey { case label, text, time = "at" }
    }

    private struct QuietRestJSON: Decodable {
        let channels: Int
        let messages: Int
    }

    private struct MoreRestJSON: Decodable {
        let channels: Int
    }
}

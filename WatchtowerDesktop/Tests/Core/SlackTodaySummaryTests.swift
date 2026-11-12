import XCTest
@testable import WatchtowerCore

/// Slack today's state as the Desktop reads it (inbox redesign phase 5):
/// the Go golden `internal/automations/builtin/testdata/slack_today_state.json`
/// (the `"today"` value the recipe writes, v 1) decoded into the row's and
/// the pane's numbers.
final class SlackTodaySummaryTests: XCTestCase {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    /// The golden's `"today"` value, wrapped as `automation_state.state_json`.
    static func goldenStateJSON() throws -> String {
        // …/WatchtowerDesktop/Tests/Core/<this file> → the repository root.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root = root.deletingLastPathComponent() }
        let url = root.appendingPathComponent("internal/automations/builtin/testdata/slack_today_state.json")
        let today = try String(contentsOf: url, encoding: .utf8)
        return #"{"today":"# + today + "}"
    }

    static func golden() throws -> SlackTodaySummary {
        try XCTUnwrap(SlackTodaySummary.decode(stateJSON: goldenStateJSON()))
    }

    func testDecodesGoldenState() throws {
        let summary = try Self.golden()
        XCTAssertEqual(summary.day, "2026-10-22")
        XCTAssertEqual(summary.messages, 210)
        // 202 entries (2 with lines, 200 quiet) + quiet_rest's 2.
        XCTAssertEqual(summary.channels, 204)
        XCTAssertEqual(summary.newsChannels, 2)
        // asks_you over needs_someone over decided over fyi, then newest.
        XCTAssertEqual(summary.topLines, [
            .init(channel: "acme-design", text: "Colleague C asks the team to pick the dark palette."),
            .init(channel: "acme-release", text: "Colleague B asks who can review the release notes.")
        ])
    }

    func testUnknownVersionIsNil() {
        let today = #""day":"2026-10-22","messages":1,"missed_yesterday":0,"channels":{},"#
            + #""quiet_rest":{"channels":0,"messages":0},"more_rest":{"channels":0,"lines":0}"#
        XCTAssertNil(SlackTodaySummary.decode(stateJSON: #"{"today":{"v":2,"# + today + "}}"))
        XCTAssertNil(SlackTodaySummary.decode(stateJSON: #"{"other":{"v":1,"# + today + "}}"))
        XCTAssertNil(SlackTodaySummary.decode(stateJSON: "{}"))
        XCTAssertNil(SlackTodaySummary.decode(stateJSON: "{not json"))
        XCTAssertNil(SlackTodaySummary.decode(stateJSON: ""))
        XCTAssertNotNil(SlackTodaySummary.decode(stateJSON: #"{"today":{"v":1,"# + today + "}}"))
    }

    func testQuietChannelsFold() throws {
        let summary = try Self.golden()
        // Quiet = no lines and nothing taken out, busiest first, then by name.
        XCTAssertEqual(summary.quiet.count, 200)
        XCTAssertEqual(summary.quiet.first, .init(name: "acme-random", messages: 2))
        XCTAssertEqual(summary.quiet[1], .init(name: "acme-quiet-0000", messages: 1))
        XCTAssertFalse(summary.quiet.contains { $0.name == "acme-release" || $0.name == "acme-design" })
        // 200 entries + 2 folded; 2 + 199 + 2 messages.
        XCTAssertEqual(summary.quietLine, "202 channels with nothing for you · 203 messages")
        XCTAssertEqual(summary.quietMoreLine, "and 2 more channels")

        let hand = try XCTUnwrap(SlackTodaySummary.decode(stateJSON: Self.state(channels: [
            #""C1":{"name":"acme-ops","n":800}"#,
            #""C2":{"name":"acme-infra","n":41,"more":3,"link":"https://example.com/a"}"#,
            #""C3":{"name":"acme-lab","n":5,"more":2,"lines":[]}"#,
            #""C4":{"name":"acme-misc","n":20}"#
        ], quietRest: (41, 0))))
        XCTAssertEqual(hand.quiet, [.init(name: "acme-ops", messages: 800), .init(name: "acme-misc", messages: 20)])
        XCTAssertEqual(hand.quietLine, "43 channels with nothing for you · 820 messages")
        XCTAssertEqual(hand.quietMoreLine, "and 41 more channels")
        // A channel with only `more` is news, not quiet.
        XCTAssertEqual(hand.newsChannels, 2)
        XCTAssertEqual(hand.channels, 45)
        XCTAssertEqual(hand.topLines, [])

        let none = try XCTUnwrap(SlackTodaySummary.decode(stateJSON: Self.state(channels: [
            #""C2":{"name":"acme-infra","n":41,"more":3,"link":"https://example.com/a"}"#
        ])))
        XCTAssertEqual(none.quiet, [])
        XCTAssertNil(none.quietLine)
        XCTAssertNil(none.quietMoreLine)

        let one = try XCTUnwrap(SlackTodaySummary.decode(stateJSON: Self.state(channels: [
            #""C1":{"name":"acme-ops","n":1}"#
        ], quietRest: (1, 4))))
        XCTAssertEqual(one.quietLine, "2 channels with nothing for you · 5 messages")
        XCTAssertEqual(one.quietMoreLine, "and 1 more channel")
        let single = try XCTUnwrap(SlackTodaySummary.decode(stateJSON: Self.state(channels: [
            #""C1":{"name":"acme-ops","n":1}"#
        ])))
        XCTAssertEqual(single.quietLine, "1 channel with nothing for you · 1 message")
        XCTAssertNil(single.quietMoreLine)
    }

    /// more_rest's channels count as news; its lines never become top lines.
    func testMoreRestCountsAsNews() throws {
        let summary = try XCTUnwrap(SlackTodaySummary.decode(stateJSON: Self.state(channels: [
            #""C1":{"name":"acme-ops","n":3,"more":0,"lines":[{"label":"fyi","text":"Deploy done.","at":"2026-10-22T09:00:00Z","link":""}]}"#
        ], moreRest: (5, 9))))
        XCTAssertEqual(summary.newsChannels, 6)
        XCTAssertEqual(summary.channels, 1)
        XCTAssertEqual(summary.topLines, [.init(channel: "acme-ops", text: "Deploy done.")])
    }

    /// Lines rank by label, then the newest first, across channels; two at most.
    func testTopLinesRankThenNewest() throws {
        let line = { (label: String, text: String, at: String) in
            #"{"label":"\#(label)","text":"\#(text)","at":"2026-10-22T\#(at):00Z","link":"https://example.com/x"}"#
        }
        let summary = try XCTUnwrap(SlackTodaySummary.decode(stateJSON: Self.state(channels: [
            #""C1":{"name":"acme-a","n":3,"more":0,"lines":["# + line("fyi", "A fyi", "09:00") + ","
                + line("decided", "A decided", "08:00") + "]}",
            #""C2":{"name":"acme-b","n":3,"more":0,"lines":["# + line("decided", "B decided", "08:30") + ","
                + line("fyi", "B fyi", "10:00") + "]}"
        ])))
        XCTAssertEqual(summary.topLines, [.init(channel: "acme-b", text: "B decided"),
                                          .init(channel: "acme-a", text: "A decided")])
    }

    func testIsTodayInTheCalendarsZone() throws {
        let summary = try Self.golden()
        let morning = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-22T10:00:00Z"))
        let next = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-23T00:30:00Z"))
        XCTAssertTrue(summary.isToday(now: morning, calendar: Self.utc))
        XCTAssertFalse(summary.isToday(now: next, calendar: Self.utc))
        var kyiv = Calendar(identifier: .gregorian)
        kyiv.timeZone = TimeZone(identifier: "Europe/Kyiv") ?? .current
        // 2026-10-22T22:30Z is already the 23rd in Kyiv.
        let late = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-22T22:30:00Z"))
        XCTAssertFalse(summary.isToday(now: late, calendar: kyiv))
    }

    /// A channel is drawn with `#`; a 1:1 DM (`@name`) and a group DM (its
    /// members' names, which hold a space) as they are — the recipe's
    /// `heading` rule.
    func testHeadingRule() {
        XCTAssertEqual(SlackTodaySummary.heading("acme-release"), "#acme-release")
        XCTAssertEqual(SlackTodaySummary.heading("@Colleague B"), "@Colleague B")
        XCTAssertEqual(SlackTodaySummary.heading("Colleague B, Colleague C"), "Colleague B, Colleague C")
    }

    /// A state with `channels` (`"<id>":{…}` members), today's day.
    static func state(
        channels: [String],
        messages: Int = 900,
        day: String = "2026-10-22",
        quietRest: (Int, Int) = (0, 0),
        moreRest: (Int, Int) = (0, 0)
    ) -> String {
        #"{"today":{"v":1,"day":"\#(day)","messages":\#(messages),"missed_yesterday":0,"channels":{"#
            + channels.joined(separator: ",")
            + #"},"quiet_rest":{"channels":\#(quietRest.0),"messages":\#(quietRest.1)},"#
            + #""more_rest":{"channels":\#(moreRest.0),"lines":\#(moreRest.1)}}}"#
    }
}

import XCTest
@testable import WatchtowerChatText

/// The cases of the Mac's `ArtifactActionsTests` for the same inputs: the phone and the Mac open the same links.
final class ArtifactLinksTests: XCTestCase {
    private func query(_ url: URL?) -> [String: String] {
        guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [:] }
        return Dictionary(items.map { ($0.name, $0.value ?? "") }) { _, last in last }
    }

    private func opened(_ link: ArtifactLink) -> URL? {
        guard case let .open(url) = link else { return nil }
        return url
    }

    func testMailtoEncodesRecipientsSubjectAndBody() throws {
        let url = try XCTUnwrap(opened(ArtifactLinks.mailto(meta: ["to": "a@x.com; b@y.com", "subject": "Hi"], body: "Body")))
        XCTAssertEqual(url.scheme, "mailto")
        XCTAssertTrue(url.absoluteString.hasPrefix("mailto:a%40x.com,b%40y.com?"))
        XCTAssertEqual(query(url)["subject"], "Hi")
        XCTAssertEqual(query(url)["body"], "Body")
    }

    func testMailtoKeepsUnicodeAndPlusEncoded() throws {
        let url = try XCTUnwrap(opened(ArtifactLinks.mailto(meta: ["to": "a@x.com", "cc": "c@x.com", "subject": #"Re: "v2" & next"#],
                                                             body: "Привіт,\nsee a+b=c")))
        XCTAssertEqual(query(url)["subject"], #"Re: "v2" & next"#)
        XCTAssertEqual(query(url)["cc"], "c@x.com")
        XCTAssertEqual(query(url)["body"], "Привіт,\nsee a+b=c")
        XCTAssertTrue(url.absoluteString.contains("a%2Bb%3Dc"), "a literal + must not turn into a space")
    }

    func testMailtoWithoutParamsStartsTheQueryAtBody() throws {
        let url = try XCTUnwrap(opened(ArtifactLinks.mailto(meta: ["to": "a@x.com"], body: "B")))
        XCTAssertEqual(url.absoluteString, "mailto:a%40x.com?body=B")
    }

    func testOverTheCapCopiesTheBodyAndOpensWithoutIt() {
        let body = String(repeating: "x", count: ArtifactLinks.maxURLLength)
        guard case let .copyThenOpen(text, url) = ArtifactLinks.mailto(meta: ["subject": "Long"], body: body) else {
            return XCTFail("expected copyThenOpen")
        }
        XCTAssertEqual(text, body)
        XCTAssertNil(query(url)["body"])
        XCTAssertEqual(query(url)["subject"], "Long")
    }

    func testCalendarTemplateConvertsToUTC() throws {
        let meta = ["title": "Design review", "start": "2026-09-30T10:00:00+03:00", "end": "2026-09-30T11:30:00+03:00",
                    "attendees": "a@x.com, b@y.com", "location": "Room 4"]
        let url = try XCTUnwrap(opened(ArtifactLinks.calendarTemplate(meta: meta, body: "Agenda")))
        XCTAssertTrue(url.absoluteString.hasPrefix("https://calendar.google.com/calendar/render?action=TEMPLATE&"))
        let items = query(url)
        XCTAssertEqual(items["text"], "Design review")
        XCTAssertEqual(items["dates"], "20260930T070000Z/20260930T083000Z")
        XCTAssertEqual(items["details"], "Agenda")
        XCTAssertEqual(items["location"], "Room 4")
        XCTAssertEqual(items["add"], "a@x.com,b@y.com")
    }

    func testCalendarLocalTimeAllDayAndMissingEnd() throws {
        let kyiv = try XCTUnwrap(TimeZone(secondsFromGMT: 3 * 3600))
        let local = try XCTUnwrap(opened(ArtifactLinks.calendarTemplate(meta: ["title": "T", "start": "2026-09-30T10:00"], body: "", timeZone: kyiv)))
        XCTAssertEqual(query(local)["dates"], "20260930T070000Z/20260930T080000Z", "no end → one hour")
        let allDay = try XCTUnwrap(opened(ArtifactLinks.calendarTemplate(meta: ["title": "T", "start": "2026-09-30"], body: "", timeZone: kyiv)))
        XCTAssertEqual(query(allDay)["dates"], "20260930/20261001")
        let undated = try XCTUnwrap(opened(ArtifactLinks.calendarTemplate(meta: ["title": "T", "start": "soon"], body: "")))
        XCTAssertNil(query(undated)["dates"])
    }

    func testSlackPermalinkOnlyWhenItIsSlack() {
        XCTAssertEqual(ArtifactLinks.slack(meta: ["permalink": "https://acme.slack.com/archives/C1/p123"])?.absoluteString,
                       "https://acme.slack.com/archives/C1/p123")
        XCTAssertEqual(ArtifactLinks.slack(meta: ["permalink": "https://evil.example/x"])?.absoluteString, "slack://open")
        XCTAssertEqual(ArtifactLinks.slack(meta: [:])?.absoluteString, "slack://open")
    }
}

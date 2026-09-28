import XCTest
@testable import WatchtowerCore

final class ArtifactActionsTests: XCTestCase {
    private func query(_ url: URL?) -> [String: String] {
        guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [:] }
        return Dictionary(items.map { ($0.name, $0.value ?? "") }) { _, last in last }
    }

    private func openedURL(_ action: ArtifactAction) -> URL? {
        guard case .open(let url) = action else { return nil }
        return url
    }

    func testGmailComposeEncodesEverything() throws {
        let meta = ["to": "anna@example.com, bo@example.com", "cc": "legal@example.com", "subject": #"Re: "v2" & next"#]
        let body = "Привіт,\nsee a+b=c"
        let url = try XCTUnwrap(openedURL(ArtifactActions.gmailComposeURL(meta: meta, body: body)))
        XCTAssertTrue(url.absoluteString.hasPrefix("https://mail.google.com/mail/?view=cm&fs=1&"))
        let items = query(url)
        XCTAssertEqual(items["to"], "anna@example.com, bo@example.com")
        XCTAssertEqual(items["cc"], "legal@example.com")
        XCTAssertEqual(items["su"], #"Re: "v2" & next"#)
        XCTAssertEqual(items["body"], body)
        XCTAssertTrue(url.absoluteString.contains("a%2Bb%3Dc"), "a literal + must not turn into a space")
    }

    func testGmailOverCapCopiesBodyAndOpensWithoutIt() throws {
        let body = String(repeating: "x", count: ArtifactActions.maxURLLength)
        guard case let .copyThenOpen(text, url) = ArtifactActions.gmailComposeURL(meta: ["subject": "Long"], body: body) else {
            return XCTFail("expected copyThenOpen")
        }
        XCTAssertEqual(text, body)
        let items = query(url)
        XCTAssertNil(items["body"])
        XCTAssertEqual(items["su"], "Long")
    }

    func testMailtoFallback() throws {
        let url = try XCTUnwrap(openedURL(ArtifactActions.mailtoURL(meta: ["to": "a@x.com; b@y.com", "subject": "Hi"], body: "Body")))
        XCTAssertEqual(url.scheme, "mailto")
        XCTAssertTrue(url.absoluteString.hasPrefix("mailto:a%40x.com,b%40y.com?"))
        XCTAssertEqual(query(url)["subject"], "Hi")
        XCTAssertEqual(query(url)["body"], "Body")
    }

    func testCalendarTemplateConvertsToUTC() throws {
        let meta = ["title": "Design review", "start": "2026-09-30T10:00:00+03:00", "end": "2026-09-30T11:30:00+03:00",
                    "attendees": "a@x.com, b@y.com", "location": "Room 4"]
        let url = try XCTUnwrap(openedURL(ArtifactActions.calendarTemplateURL(meta: meta, body: "Agenda")))
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
        let local = try XCTUnwrap(openedURL(ArtifactActions.calendarTemplateURL(
            meta: ["title": "T", "start": "2026-09-30T10:00"], body: "", timeZone: kyiv)))
        XCTAssertEqual(query(local)["dates"], "20260930T070000Z/20260930T080000Z", "no end → one hour")
        let allDay = try XCTUnwrap(openedURL(ArtifactActions.calendarTemplateURL(
            meta: ["title": "T", "start": "2026-09-30"], body: "", timeZone: kyiv)))
        XCTAssertEqual(query(allDay)["dates"], "20260930/20261001")
        let undated = try XCTUnwrap(openedURL(ArtifactActions.calendarTemplateURL(meta: ["title": "T", "start": "soon"], body: "")))
        XCTAssertNil(query(undated)["dates"])
    }

    func testSlackTarget() {
        let links = SlackLinkResolver(teamIDByAccount: [1: "T1"], fallbackTeamID: "T0")
        XCTAssertEqual(ArtifactActions.slackTarget(meta: ["permalink": "https://acme.slack.com/archives/C1/p123"])?.absoluteString,
                       "https://acme.slack.com/archives/C1/p123")
        XCTAssertEqual(ArtifactActions.slackTarget(meta: ["permalink": "https://evil.example/x", "channel": "1:C0123"], links: links)?.absoluteString,
                       "slack://channel?team=T1&id=C0123", "a non-Slack permalink is ignored")
        XCTAssertEqual(ArtifactActions.slackTarget(meta: ["channel": "1:C0123", "thread_ts": "1727000000.000100"], links: links)?.absoluteString,
                       "slack://channel?team=T1&id=C0123&message=1727000000.000100")
        XCTAssertEqual(ArtifactActions.slackTarget(meta: ["channel": "1:C0123", "thread_ts": "1727000000.000100"])?.absoluteString,
                       "https://slack.com/archives/C0123/p1727000000000100")
        XCTAssertNil(ArtifactActions.slackTarget(meta: ["channel": "#general"]))
        XCTAssertNil(ArtifactActions.slackTarget(meta: [:]))
    }

    func testKindActions() {
        let email = ArtifactDraft(key: "e", kind: "email", title: "E", meta: ["to": "a@x.com"], content: "B", isComplete: true)
        XCTAssertEqual(ArtifactActions.kindActions(for: email, gmailConnected: true, slackLinks: nil).map(\.title),
                       ["Open in Gmail", "Open in Mail"])
        XCTAssertEqual(ArtifactActions.kindActions(for: email, gmailConnected: false, slackLinks: nil).map(\.title), ["Open in Mail"])
        let slack = ArtifactDraft(key: "s", kind: "slack", title: "S", meta: ["channel": "C1"], content: "hello", isComplete: true)
        XCTAssertEqual(ArtifactActions.kindActions(for: slack, gmailConnected: false, slackLinks: nil).map(\.action),
                       [.copyThenOpen(text: "hello", url: URL(string: "https://slack.com/app_redirect?channel=C1"))])
        let doc = ArtifactDraft(key: "d", kind: "document", title: "D", meta: [:], content: "x", isComplete: true)
        XCTAssertEqual(ArtifactActions.kindActions(for: doc, gmailConnected: true, slackLinks: nil), [])
    }

    func testExportFile() {
        func draft(_ kind: String, _ meta: [String: String] = [:]) -> ArtifactDraft {
            ArtifactDraft(key: "k", kind: kind, title: "Q3 План", meta: meta, content: "Body", isComplete: true)
        }
        XCTAssertEqual(ArtifactActions.exportFile(for: draft("document")).name, "q3-план.md")
        XCTAssertEqual(ArtifactActions.exportFile(for: draft("table")).name, "q3-план.csv")
        XCTAssertEqual(ArtifactActions.exportFile(for: draft("code", ["language": "python"])).name, "q3-план.py")
        XCTAssertEqual(ArtifactActions.exportFile(for: draft("code")).name, "q3-план.txt")
        let email = ArtifactActions.exportFile(for: draft("email", ["to": "a@x.com", "subject": "Hi"]))
        XCTAssertEqual(email.name, "q3-план.txt")
        XCTAssertEqual(email.contents, "To: a@x.com\nSubject: Hi\n\nBody")
    }

    /// CHAT-05 — artifacts never send: every action any artifact kind can
    /// produce is a copy or an open of a compose/deep-link URL; there is no
    /// action value that could perform a network or CLI write.
    /// BEHAVIOR CHAT-05 — see docs/inventory/chat.md
    func testChat05ArtifactActionsOnlyOpenOrCopy() {
        let rich: [String: String] = [
            "to": "a@x.com", "cc": "b@x.com", "subject": "S", "channel": "1:C1", "thread_ts": "1.2",
            "permalink": "https://acme.slack.com/archives/C1/p12", "start": "2026-09-30T10:00:00Z",
            "end": "2026-09-30T11:00:00Z", "attendees": "a@x.com", "location": "L", "language": "go"
        ]
        let links = SlackLinkResolver(teamIDByAccount: [1: "T1"], fallbackTeamID: "T0")
        for kind in ArtifactParser.knownKinds.sorted() {
            for body in ["short", String(repeating: "y", count: ArtifactActions.maxURLLength)] {
                let draft = ArtifactDraft(key: "k", kind: kind, title: "T", meta: rich, content: body, isComplete: true)
                for gmail in [true, false] {
                    for item in ArtifactActions.kindActions(for: draft, gmailConnected: gmail, slackLinks: links) {
                        switch item.action {
                        case .copy:
                            break
                        case .open(let url):
                            assertComposeOrDeepLink(url, kind: kind)
                        case .copyThenOpen(_, let url):
                            if let url { assertComposeOrDeepLink(url, kind: kind) }
                        }
                    }
                }
            }
        }
    }

    private func assertComposeOrDeepLink(_ url: URL, kind: String, file: StaticString = #filePath, line: UInt = #line) {
        switch url.scheme {
        case "mailto", "slack":
            return
        case "https":
            let host = url.host ?? ""
            let allowed = host == "mail.google.com" || host == "calendar.google.com" || host == "slack.com" || host.hasSuffix(".slack.com")
            XCTAssertTrue(allowed, "\(kind): unexpected host \(host)", file: file, line: line)
        default:
            XCTFail("\(kind): unexpected scheme in \(url)", file: file, line: line)
        }
    }
}

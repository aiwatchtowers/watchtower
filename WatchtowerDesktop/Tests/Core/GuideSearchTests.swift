import Foundation
import Testing
@testable import WatchtowerCore

@Suite("GuideSearch")
struct GuideSearchTests {
    static let sections = [
        GuideSection(page: "calendar/", pageTitle: "Calendar", heading: "Syncing events", anchor: "syncing-events",
                     level: 2, text: "Events appear after the first sync. A recap is not part of this page."),
        GuideSection(page: "catchup/", pageTitle: "Catch-Up", heading: "Get a recap", anchor: "get-a-recap",
                     level: 2, text: "Open Catch-Up to see what changed while you were away."),
        GuideSection(page: "inbox/", pageTitle: "Inbox", heading: "Reading items", anchor: "reading-items",
                     level: 2, text: "Items wait here.")
    ]

    @Test("a heading match outranks a text match")
    func rankPrefersHeading() {
        let r = GuideSearch.rank("recap", in: Self.sections, limit: 5)
        #expect(r.map(\.anchor) == ["get-a-recap", "syncing-events"])
    }

    @Test("no match is empty")
    func rankEmptyForNoMatch() {
        #expect(GuideSearch.rank("zzzzqq", in: Self.sections, limit: 5).isEmpty)
        #expect(GuideSearch.rank("a", in: Self.sections, limit: 5).isEmpty)
    }

    @Test("ties keep input order and limit applies")
    func tiesAndLimit() {
        let r = GuideSearch.rank("items", in: Self.sections, limit: 1)
        #expect(r.count == 1)
        #expect(GuideSearch.rank("page", in: Self.sections, limit: 5).first?.anchor == "syncing-events")
    }

    @Test("a follow-up query carries the previous question")
    func followUpUsesPreviousQuestion() {
        let r = GuideSearch.rank("and then? " + "how do I get a recap", in: Self.sections, limit: 3)
        #expect(r.first?.anchor == "get-a-recap")
    }

    @Test("the index fixture decodes and builds section URLs")
    func decodesIndexFixture() throws {
        let json = """
        {"version":"1","base_url":"https://docs.example.com/","catalog":"- Calendar",
         "sections":[
          {"page":"calendar/","page_title":"Calendar","heading":"Syncing","anchor":"syncing","level":2,"text":"t"},
          {"page":"inbox/","page_title":"Inbox","heading":"Items","anchor":"items","level":3,"text":"u"}]}
        """
        let index = try JSONDecoder().decode(GuideIndex.self, from: Data(json.utf8))
        #expect(index.sections.count == 2)
        #expect(index.catalog == "- Calendar")
        let s = index.sections[0]
        #expect(s.id == "calendar/#syncing")
        #expect(s.url(in: index)?.absoluteString == "https://docs.example.com/calendar/#syncing")
    }
}

extension GuideSearchTests {
    @Test("a word adds every field it prefixes, however often, and query words split on whitespace")
    func additiveScoringAndWhitespaceWords() {
        // "calendar" is a heading word (3) and a title word (2) of a: 5; twice in b's text: still 1.
        let a = GuideSection(page: "a/", pageTitle: "Calendar", heading: "Calendar basics", anchor: "a", level: 2, text: "x")
        let b = GuideSection(page: "b/", pageTitle: "Other", heading: "Misc", anchor: "b", level: 2, text: "calendar calendar")
        #expect(GuideSearch.rank("calendar", in: [b, a], limit: 5).map(\.anchor) == ["a", "b"])
        #expect(GuideSearch.rank("zzzz-no-match", in: [a, b], limit: 5).isEmpty)
    }
}

extension GuideSearchTests {
    @Test("punctuation around query words is trimmed")
    func trimsPunctuation() {
        #expect(GuideSearch.rank("recap?", in: Self.sections, limit: 5).first?.anchor == "get-a-recap")
        #expect(GuideSearch.rank("how do I get a recap?", in: Self.sections, limit: 5).first?.anchor == "get-a-recap")
    }
}

/// internal/userguide/testdata/queries.json, shared with the Go ranker's tests: the same
/// stopwords, and each natural question's top section on its snapshot of real guide sections.
extension GuideSearchTests {
    private struct Fixture: Decodable {
        struct Query: Decodable {
            let query: String
            let top: String
        }
        let stopwords: [String]
        let queries: [Query]
        let sections: [GuideSection]
    }

    private static func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // the repository
            .appendingPathComponent("internal/userguide/testdata/queries.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    @Test("the stopwords are Go's")
    func stopwordsMatchGo() throws {
        #expect(GuideSearch.stopwords == Set(try Self.fixture().stopwords))
    }

    @Test("natural questions find the section Go finds")
    func naturalQuestionsMatchGo() throws {
        let fixture = try Self.fixture()
        for query in fixture.queries {
            let top = GuideSearch.rank(query.query, in: fixture.sections, limit: 1).first?.id ?? ""
            #expect(top == query.top, "\(query.query)")
        }
    }

    @Test("text words match by prefix, not substring; a possessive matches the bare word")
    func wordPrefixNotSubstring() {
        let a = GuideSection(page: "a.md", pageTitle: "Alpha", heading: "Why use it", anchor: "", level: 1,
                             text: "Show the item.")
        let b = GuideSection(page: "b.md", pageTitle: "Beta", heading: "Reminders", anchor: "", level: 1,
                             text: "A reminder fires before the event.")
        #expect(GuideSearch.rank("how do I set a remind", in: [a, b], limit: 5).map(\.page) == ["b.md"])
        #expect(GuideSearch.rank("tem", in: [a, b], limit: 5).isEmpty)
        #expect(GuideSearch.rank("event\u{2019}s", in: [a, b], limit: 5).map(\.page) == ["b.md"])
    }
}

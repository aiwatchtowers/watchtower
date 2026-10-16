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
                     level: 2, text: "Items wait here."),
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

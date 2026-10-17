import Testing
@testable import WatchtowerCore

@Suite("HelpPrompt")
struct HelpPromptTests {
    @Test("nothing matched says so and keeps the question")
    func turnPromptWhenNothingMatches() {
        let p = HelpPrompt.turn(question: "how do I fly?", previousQuestion: nil, currentPage: "Calendar",
                                screens: [HelpScreen(rawValue: "calendar", title: "Calendar")], sections: [])
        #expect(p.contains("Guide sections: none matched"))
        #expect(p.contains("Question: how do I fly?"))
        #expect(p.contains("Current page: Calendar"))
    }

    @Test("only the given screens are listed")
    func turnPromptListsOnlyGivenScreens() {
        let p = HelpPrompt.turn(question: "q", previousQuestion: nil, currentPage: "Calendar",
                                screens: [HelpScreen(rawValue: "calendar", title: "Calendar")], sections: [])
        #expect(p.contains("calendar=Calendar"))
        #expect(!p.contains("projects"))
    }

    @Test("sections are formatted with title and heading")
    func sectionsFormatted() {
        let s = GuideSection(page: "p/", pageTitle: "Inbox", heading: "Items", anchor: "items", level: 2, text: "Body.")
        let p = HelpPrompt.turn(question: "q", previousQuestion: nil, currentPage: "x", screens: [], sections: [s])
        #expect(p.contains("Guide sections:\n### Inbox › Items\nBody."))
    }

    @Test("system prompt carries the rules and the catalog")
    func systemPrompt() {
        let p = HelpPrompt.system(catalog: "- Inbox")
        #expect(p.contains("watchtower-nav://<screen>"))
        #expect(p.contains("Never invent features"))
        #expect(p.hasSuffix("Guide contents:\n- Inbox"))
    }
}

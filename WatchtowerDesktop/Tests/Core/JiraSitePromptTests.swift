import Foundation
import Testing
@testable import WatchtowerCore

@Suite("JiraSitePrompt")
struct JiraSitePromptTests {
    private let line = #"[jira-sites] {"sites":[{"url":"https://alpha.atlassian.net","name":"Alpha"},"#
        + #"{"url":"https://beta.atlassian.net","name":"Beta"}]}"#

    @Test("the marker line, once complete, gives the sites in order")
    func parsesCompleteLine() {
        let output = "Opening the browser…\n" + line + "\n"
        #expect(JiraSitePrompt.sites(in: output) == [
            JiraSiteChoice(url: "https://alpha.atlassian.net", name: "Alpha"),
            JiraSiteChoice(url: "https://beta.atlassian.net", name: "Beta")
        ])
    }

    @Test("a line still arriving gives nothing yet")
    func waitsForTheNewline() {
        #expect(JiraSitePrompt.sites(in: line) == nil)
        #expect(JiraSitePrompt.sites(in: String(line.prefix(30))) == nil)
    }

    @Test("other output, a broken payload or an empty list give nothing")
    func ignoresOtherOutput() {
        #expect(JiraSitePrompt.sites(in: "Jira Cloud connected\n") == nil)
        #expect(JiraSitePrompt.sites(in: "[jira-sites] {oops\n") == nil)
        #expect(JiraSitePrompt.sites(in: #"[jira-sites] {"sites":[]}"# + "\n") == nil)
    }

    @Test("the answer is the chosen URL on one line")
    func answer() {
        let site = JiraSiteChoice(url: "https://beta.atlassian.net", name: "Beta")
        #expect(String(bytes: JiraSitePrompt.answer(site), encoding: .utf8) == "https://beta.atlassian.net\n")
    }
}

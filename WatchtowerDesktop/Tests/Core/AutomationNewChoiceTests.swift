import XCTest
@testable import WatchtowerCore

final class AutomationNewChoiceTests: XCTestCase {
    /// The five templates in `automations templates --json` order.
    private static let names: [(String, String)] = [
        ("new-mail-summary", "personal"), ("pr-review-rounds", "workbench"), ("jira-state-report", "personal"),
        ("team-performance-report", "personal"), ("release-buttons", "workbench")
    ]

    private func templates() throws -> [AutomationTemplate] {
        try Self.names.map { name, scope in
            let json = #"{"name":"\#(name)","title":"T","description":"D","scope":"\#(scope)"}"#
            return try JSONDecoder().decode(AutomationTemplate.self, from: Data(json.utf8))
        }
    }

    func testStartsListWordsFirstThenMatchingTemplates() throws {
        let all = try templates()
        XCTAssertEqual(AutomationNewChoice.starts(templates: all, scope: .personal),
                       [.words, .template("new-mail-summary"), .template("jira-state-report"),
                        .template("team-performance-report")])
        let workbench = AutomationScopeChoice.workbench(id: 3, name: "acme", folder: "/work/acme")
        XCTAssertEqual(AutomationNewChoice.starts(templates: all, scope: workbench),
                       [.words, .template("pr-review-rounds"), .template("release-buttons")])
    }

    func testNoTemplatesOnlyWords() {
        XCTAssertEqual(AutomationNewChoice.starts(templates: [], scope: .personal), [.words])
        XCTAssertEqual(AutomationNewChoice.starts(templates: [], scope: .workbench(id: 3, name: "acme", folder: "/w")),
                       [.words])
    }
}

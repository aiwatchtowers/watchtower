import XCTest
@testable import WatchtowerDesktop

@MainActor
final class CatchUpViewModelTests: XCTestCase {
    func testParsesResultJSON() throws {
        let json = """
        {"tldr":"Caught up.","truncated":true,
         "counts":{"digests":{"included":1,"total":3},"tracks":{"included":0,"total":0},
                   "inbox":{"included":0,"total":0},"briefings":{"included":0,"total":0},
                   "total_unread":3,"total_included":1},
         "stories":[{"title":"S","narrative":"N","priority":"high","needs_you":true,
                     "refs":[{"area":"digests","id":1,"label":"x"}]}],
         "sections":[{"area":"digests","total":3,"included":1,
                      "items":[{"id":1,"title":"t","snippet":"s"}]}]}
        """
        let result = try JSONDecoder().decode(CatchUpResult.self, from: Data(json.utf8))
        XCTAssertEqual(result.tldr, "Caught up.")
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.stories.count, 1)
        XCTAssertEqual(result.stories[0].priority, "high")
        XCTAssertEqual(result.sections.first?.items.first?.id, 1)
        XCTAssertEqual(result.counts.totalUnread, 3)
    }

    func testSnapshotIDsPerArea() throws {
        let json = """
        {"tldr":"","truncated":false,
         "counts":{"digests":{"included":2,"total":2},"tracks":{"included":1,"total":1},
                   "inbox":{"included":0,"total":0},"briefings":{"included":0,"total":0},
                   "total_unread":3,"total_included":3},
         "stories":[],
         "sections":[{"area":"digests","total":2,"included":2,
                      "items":[{"id":7,"title":"a","snippet":""},{"id":8,"title":"b","snippet":""}]},
                     {"area":"tracks","total":1,"included":1,
                      "items":[{"id":42,"title":"c","snippet":""}]}]}
        """
        let result = try JSONDecoder().decode(CatchUpResult.self, from: Data(json.utf8))
        XCTAssertEqual(result.ids(for: "digests"), [7, 8])
        XCTAssertEqual(result.ids(for: "tracks"), [42])
        XCTAssertEqual(result.ids(for: "inbox"), [])
    }
}

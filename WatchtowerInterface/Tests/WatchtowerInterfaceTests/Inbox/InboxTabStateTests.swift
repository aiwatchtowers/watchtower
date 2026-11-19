import WatchtowerInterface
import XCTest

final class InboxTabStateTests: XCTestCase {
    private typealias Fix = InboxFixtures

    func testLoading() {
        let state = InboxTabState.resolve(capability: "inbox", fetched: false, feed: nil, hubName: "Acme Mac", macAway: nil)
        XCTAssertEqual(state, .loading(hub: "Acme Mac"))
        XCTAssertEqual(state.copy?.title, "Getting your Inbox from Acme Mac…")
    }

    func testEmpty() {
        let feed = Fix.feed(folders: [Fix.root])
        let state = InboxTabState.resolve(capability: "inbox", fetched: true, feed: feed, hubName: "Acme Mac", macAway: nil)
        XCTAssertEqual(state, .empty(hub: "Acme Mac"))
        XCTAssertEqual(state.copy?.title, "Nothing waits for you")
        XCTAssertEqual(state.copy?.body, "New cards arrive after the next sync on Acme Mac.")
    }

    func testReady() throws {
        let state = InboxTabState.resolve(capability: "inbox", fetched: true, feed: try Fix.golden(), hubName: "Acme Mac", macAway: nil)
        XCTAssertEqual(state, .ready)
        XCTAssertNil(state.copy)
    }

    func testTooOldOnAMissingKey() throws {
        let state = InboxTabState.resolve(capability: nil, fetched: true, feed: try Fix.golden(), hubName: "Acme Mac", macAway: nil)
        XCTAssertEqual(state, .tooOld(hub: "Acme Mac"))
        XCTAssertEqual(state.copy?.title, "Update Watchtower on Acme Mac")
        XCTAssertEqual(state.copy?.body, "Watchtower on Acme Mac is too old to send its Inbox to the phone.")
    }

    func testPolicyOff() {
        let state = InboxTabState.resolve(capability: "policy_off", fetched: false, feed: nil, hubName: "Acme Mac", macAway: nil)
        XCTAssertEqual(state, .policyOff)
        XCTAssertEqual(state.copy?.title, "The Inbox stays on your Mac")
        XCTAssertEqual(state.copy?.body, "Your organization lets this phone see only Workbench.")
    }

    func testMacAway() throws {
        let asOf = try Fix.date("2026-11-16T11:20:00Z")
        let state = InboxTabState.resolve(capability: "inbox", fetched: true, feed: try Fix.golden(), hubName: "Acme Mac", macAway: asOf)
        XCTAssertEqual(state, .macAway(hub: "Acme Mac", asOf: asOf))
        XCTAssertNil(state.copy)
    }
}

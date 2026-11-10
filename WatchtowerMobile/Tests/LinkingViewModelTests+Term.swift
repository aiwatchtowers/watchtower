import Foundation
import WatchtowerE2ETesting
import XCTest
@testable import WatchtowerMobile

private let termAcme = TestE2E.hubID.uuidString
private let termHome = "40E00000-0000-4000-8000-000000000004"

// MARK: - The term's notices (relay client Phase 5, Task 17, S60)

extension LinkingViewModelTests {
    private func twoLinkedMacs() async throws -> LinkingViewModel {
        let model = try await linkedModel(code())
        let home = code(hubID: termHome, macName: "Home Mac")
        macLinks(home)
        await model.open(home.url())
        await model.finish()
        XCTAssertEqual(model.links.map(\.hubID), [termAcme, termHome])
        return model
    }

    func testTheNoticeNamesTheMacAndTheNotSentCount() async throws {
        XCTAssertEqual(
            LinkNotice.relayEnded(macName: "Work Mac", notSent: 0).message,
            "The link to Work Mac ended after 21 days without Relay. Link it again to see its data.")
        XCTAssertEqual(
            LinkNotice.relayEnded(macName: "Work Mac", notSent: 2).message,
            "The link to Work Mac ended after 21 days without Relay. Link it again to see its data. "
                + "Not sent: 2 items were still waiting for your Mac")
        XCTAssertEqual(LinkNotice.relayEnded(macName: "Work Mac", notSent: 0).dismissTitle, "OK")

        let model = try await linkedModel(code())
        host.notSentCount = 2
        await model.endAtTerm(termAcme)
        XCTAssertTrue(model.links.isEmpty, "the row goes, as with Forget")
        XCTAssertEqual(host.removedHubIDs, [termAcme])
        XCTAssertEqual(model.notice, .relayEnded(macName: "Acme Mac", notSent: 2))
    }

    /// The end is today's unlink: the farewell through the hub's own transport (kept when refused, the host's), the row,
    /// the keys, the local data; recordings stay.
    func testTheTermSendsTheFarewell() async throws {
        let model = try await linkedModel(code())
        host.keepsFarewell = true
        await model.endAtTerm(termAcme)
        XCTAssertEqual(host.farewells.map(\.hubID), [termAcme], "the farewell went to the hub's transport")
        XCTAssertNil(try keyStore.hubLink(termAcme), "every key goes")
        XCTAssertTrue(model.links.isEmpty)
    }

    /// A re-link after the term is a new link: no term mark and no S59 on it.
    func testARelinkStartsWithoutLinkGone() async throws {
        let model = try await linkedModel(code())
        await model.endAtTerm(termAcme)
        let again = code()
        macLinks(again)
        await model.open(again.url())
        await model.finish()
        let link = try XCTUnwrap(model.links.first?.link)
        XCTAssertNil(link.relayRefused)
        XCTAssertNil(link.macMoved)
    }

    func testARecordingProblemWinsOverTheTermsNotice() async throws {
        let model = try await linkedModel(code())
        host.recordingProblem = "Some recordings couldn't be read (disk full)"
        host.notSentCount = 1
        await model.endAtTerm(termAcme)
        XCTAssertEqual(model.notice, .recordingsProblem("Some recordings couldn't be read (disk full)", notSent: 1))
    }

    func testTwoLinksEndingInOneForegroundEachGetTheirNotice() async throws {
        let model = try await twoLinkedMacs()
        await model.endAtTerm(termAcme)
        await model.endAtTerm(termHome)
        XCTAssertEqual(model.notice, .relayEnded(macName: "Acme Mac", notSent: 0), "the first, one at a time")
        model.dismissNotice()
        XCTAssertEqual(model.notice, .relayEnded(macName: "Home Mac", notSent: 0), "the next shows after OK")
        model.dismissNotice()
        XCTAssertNil(model.notice)
    }

    func testNoNotSentCountIsLostWhenLinksEndTogether() async throws {
        let model = try await twoLinkedMacs()
        host.notSentCount = 3
        await model.endAtTerm(termAcme)
        host.notSentCount = 2
        await model.endAtTerm(termHome)
        XCTAssertEqual(model.termNotices, [
            .relayEnded(macName: "Acme Mac", notSent: 3), .relayEnded(macName: "Home Mac", notSent: 2)
        ])
    }

    func testARecordingProblemKeepsItsPlaceInTheQueue() async throws {
        let model = try await twoLinkedMacs()
        host.recordingProblem = "Some recordings couldn't be read (disk full)"
        await model.endAtTerm(termAcme)
        await model.endAtTerm(termHome)
        XCTAssertEqual(model.termNotices, [
            .recordingsProblem("Some recordings couldn't be read (disk full)", notSent: 0),
            .relayEnded(macName: "Home Mac", notSent: 0)
        ])
    }

    /// Nothing but `dismissNotice` takes a queued notice: no scan, no stale notice, no other removal's report.
    func testAnotherNoticeDoesNotOverwriteAQueuedOne() async throws {
        let model = try await twoLinkedMacs()
        await model.endAtTerm(termAcme)
        host.notSentCount = 4
        await model.unlink(termHome)
        XCTAssertEqual(model.notice, .relayEnded(macName: "Acme Mac", notSent: 0), "the queue goes first")
        model.startScan()
        model.dismiss()
        XCTAssertEqual(model.notice, .relayEnded(macName: "Acme Mac", notSent: 0), "a scan clears no queued notice")
        model.dismissNotice()
        XCTAssertNil(model.notice, "the scan cleared the unlink's own report; the queue is empty")
    }
}

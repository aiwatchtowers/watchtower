import XCTest
@testable import WatchtowerCore

/// Every line of merging benches (#2003, spec §6.13), verbatim.
final class BenchMergePresentationTests: XCTestCase {
    typealias Copy = BenchMergePresentation

    func testConfirmation() {
        XCTAssertEqual(Copy.confirmTitle(from: "tools", into: "acme"), "Merge “tools” into “acme”?")
        XCTAssertEqual(
            Copy.confirmText(from: "tools", into: "acme", targets: 12, folders: ["tools", "billing"]),
            "tools's board (12 targets), asks and sessions move to acme, and tools leaves the workbench list. "
                + "Folders that move: tools, billing."
        )
        XCTAssertEqual(Copy.cancel, "Cancel")
        XCTAssertEqual(Copy.merge, "Merge")
    }

    func testOfferReadsAsTheConfirmation() {
        let offer = BenchMergeOffer(
            fromID: 9, fromName: "tools", intoID: 1, intoName: "acme", targets: 3, folders: ["tools"],
            path: "/tmp/tools", askID: nil
        )
        XCTAssertEqual(offer.title, "Merge “tools” into “acme”?")
        XCTAssertEqual(
            offer.text,
            "tools's board (3 targets), asks and sessions move to acme, and tools leaves the workbench list. Folders that move: tools."
        )
    }

    func testRefusedSingularAndPlural() {
        XCTAssertEqual(Copy.refusedTitle(from: "tools"), "Can’t merge “tools” yet")
        XCTAssertEqual(Copy.refusedText(from: "tools", running: 1), "1 session is running in tools. Finish it first.")
        XCTAssertEqual(Copy.refusedText(from: "tools", running: 3), "3 sessions are running in tools. Finish them first.")
        XCTAssertEqual(Copy.ok, "OK")
        let refusal = BenchMergeRefusal(fromName: "tools", running: 2)
        XCTAssertEqual(refusal.title, "Can’t merge “tools” yet")
        XCTAssertEqual(refusal.text, "2 sessions are running in tools. Finish them first.")
    }

    func testFailedLine() {
        XCTAssertEqual(Copy.failed(from: "tools", reason: "disk full"), "Couldn’t merge “tools”: disk full")
    }

    func testCardVariant() {
        XCTAssertEqual(Copy.cardLine(name: "billing", bench: "tools"), "billing is on the “tools” bench")
        XCTAssertEqual(Copy.mergeBenches, "Merge Benches…")
        XCTAssertEqual(Copy.notNow, "Not Now")
    }
}

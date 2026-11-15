import XCTest
@testable import WatchtowerCore

/// Mail waiting's **Mute Senders…** panel: the ten busiest unmuted senders
/// with an address, none ticked, one button whose title follows the count,
/// one rule per ticked sender in row order, stopping at the first failure.
@MainActor
final class MuteSendersModelTests: XCTestCase {
    private struct Boom: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func row(_ address: String, open: Int) -> MailSenderRow {
        MailSenderRow(address: address, open: open, today: 0, subject: "Weekly report")
    }

    /// Twelve senders, busiest first, one of them without an address.
    private static let senders: [MailSenderRow] = [row("alerts@example.com", open: 40), row("", open: 30)]
        + (1...10).map { row("sender\($0)@example.com", open: 20 - $0) }

    private func loaded(
        _ rows: [MailSenderRow] = senders,
        mute: @escaping (String) async throws -> Void = { _ in }
    ) async -> MuteSendersModel {
        let model = MuteSendersModel(load: { rows }, mute: mute)
        await model.load()
        return model
    }

    func testNothingTickedAtStart() async {
        let model = await loaded()
        XCTAssertFalse(model.rows.isEmpty)
        XCTAssertEqual(model.selected, [])
        XCTAssertFalse(model.canApply)
    }

    func testTitlesByCount() async {
        let model = await loaded()
        XCTAssertEqual(model.buttonTitle, "Mute Senders")
        XCTAssertFalse(model.canApply)
        model.selected = ["alerts@example.com"]
        XCTAssertEqual(model.buttonTitle, "Mute 1 Sender")
        XCTAssertTrue(model.canApply)
        model.selected = ["alerts@example.com", "sender1@example.com", "sender2@example.com"]
        XCTAssertEqual(model.buttonTitle, "Mute 3 Senders")
        XCTAssertTrue(model.canApply)
    }

    func testRowsAreTheTenBusiestUnmuted() async {
        let model = await loaded()
        // The no-address row is never offered; the next sender takes its place.
        XCTAssertEqual(model.rows.map(\.address),
                       ["alerts@example.com"] + (1...9).map { "sender\($0)@example.com" })
        XCTAssertFalse(model.rows.contains { $0.address.isEmpty })
    }

    func testApplyMutesEachTickedSenderOnce() async {
        var muted: [String] = []
        let model = await loaded { muted.append($0) }
        // Ticked out of row order: written in row order.
        model.selected = ["sender3@example.com", "alerts@example.com"]

        let result = await model.apply()

        XCTAssertEqual(result, .done(2))
        XCTAssertEqual(muted, ["alerts@example.com", "sender3@example.com"])
        XCTAssertNil(model.failureLine)
    }

    func testApplyStopsAtFirstFailureAndReports() async {
        var muted: [String] = []
        var failing = true
        let model = await loaded { address in
            if failing, address == "sender2@example.com" { throw Boom(message: "The database was busy.") }
            muted.append(address)
        }
        model.selected = ["alerts@example.com", "sender2@example.com", "sender5@example.com"]

        let result = await model.apply()

        XCTAssertEqual(result, .partial(done: 1, of: 3, error: "The database was busy."))
        XCTAssertEqual(muted, ["alerts@example.com"])
        XCTAssertEqual(model.failureLine, "Muted 1 of 3. The database was busy.")
        // The muted sender leaves the panel; the rest stay ticked for another press.
        XCTAssertFalse(model.rows.contains { $0.address == "alerts@example.com" })
        XCTAssertEqual(model.selected, ["sender2@example.com", "sender5@example.com"])

        // Another press writes only what is left, each once.
        failing = false
        muted = []
        let again = await model.apply()
        XCTAssertEqual(again, .done(2))
        XCTAssertEqual(muted, ["sender2@example.com", "sender5@example.com"])
        XCTAssertNil(model.failureLine)
    }

    func testLoadFailureShowsError() async {
        let model = MuteSendersModel(load: { throw Boom(message: "The Inbox could not be read.") }, mute: { _ in })
        await model.load()
        XCTAssertEqual(model.loadError, "The Inbox could not be read.")
        XCTAssertEqual(model.rows, [])
        XCTAssertFalse(model.canApply)
    }

    func testEmptyLoadOffersNothing() async {
        let model = await loaded([Self.row("", open: 4)])
        XCTAssertEqual(model.rows, [])
        XCTAssertNil(model.loadError)
        XCTAssertFalse(model.canApply)
    }
}

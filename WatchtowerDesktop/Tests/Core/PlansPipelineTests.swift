import XCTest
import WatchtowerTestSupport
@testable import WatchtowerCore

final class PlansPipelineTests: XCTestCase {
    func testRawCodexPublicationReachesProductionQueriesAndPresentation() throws {
        let queue = try TestDatabase.create()
        let fixture = try queue.write { try PlansPipelineFixture.load($0) }
        let wire = try XCTUnwrap(fixture.envelope.providers.first?.status)
        XCTAssertEqual(fixture.envelope.requestedProvider, "codex")
        XCTAssertTrue(fixture.envelope.providers[0].ok)
        XCTAssertTrue(fixture.status.historyAvailable)
        XCTAssertEqual(fixture.status.limits.count, 2)
        let screen = PlansScreenPresentation(claude: nil, codex: fixture.status, now: fixture.now)
        let codex = screen.providers[1]
        XCTAssertEqual(screen.statusTitle, "Codex may run out before reset")
        XCTAssertEqual(codex.primary?.tone, .warning)
        for limit in fixture.status.limits {
            let history = try XCTUnwrap(fixture.status.history[limit.key])
            XCTAssertEqual(history.count, 2, "foreign scope/reset and unpublished rows in the Go bundle stay excluded")
            XCTAssertEqual(history.last?.takenAt, fixture.status.fetchedAt)
            let expected = try XCTUnwrap(wire.limits.first { $0.key == limit.key })
            let forecast = try fixture.status.forecast(for: limit, now: fixture.now)
            XCTAssertEqual(forecast.line, expected.projection.line, "Swift renders the exact published Go endpoint")
            XCTAssertEqual(forecast.state, expected.projection.state)
            XCTAssertTrue(forecast.drawable)
        }
        XCTAssertNotNil(codex.selected(.weekly)?.line)
        XCTAssertNotNil(codex.selected(.session)?.line)
        XCTAssertEqual(codex.selected(.weekly)?.line?.endPercent, 100)
        XCTAssertEqual(try XCTUnwrap(codex.selected(.session)?.line?.endPercent), 80, accuracy: 0.0000000001)
    }
}

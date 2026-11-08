import AppKit
import GRDB
import SwiftUI
import XCTest
import WatchtowerCore
import WatchtowerTestSupport
@testable import WatchtowerDesktop

@MainActor
final class PlansPipelineScreenTests: XCTestCase {
    func testProductionContentRendersTheRawRPCPublicationFixture() throws {
        let queue = try TestDatabase.create()
        let fixture = try queue.write { try PlansPipelineFixture.load($0) }
        let model = PlansScreenPresentation(claude: nil, codex: fixture.status, now: fixture.now)
        let view = PlansContent(model: model, period: .constant(.weekly), showInMenuBar: .constant(true),
                                refresh: { _ in }, refreshAll: {})
        let probe = ViewRenderProbe(size: NSSize(width: 1120, height: 1340))
        let appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let png = try probe.png(view, appearance)
        XCTAssertGreaterThan(png.count, 1000)
        XCTAssertEqual(model.providers[1].selected(.weekly)?.line,
                       fixture.envelope.providers[0].status?.limits.first?.projection.line)
    }
}

import SwiftUI
import ViewInspector
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The company setup wizard's page (#1887 Task 22, company screens spec §2.2).
@MainActor
final class CompanySetupPageTests: XCTestCase {
    private typealias Model = CompanySetupWizardModel

    private func opened() async -> (Model, CompanyScriptedCLI) {
        let cli = CompanyScriptedCLI()
        let model = Model(streamer: cli, slack: SlackAppSetupModel(streamer: cli, mode: .wizard))
        await model.open()
        return (model, cli)
    }

    /// Under 520 pt the rail folds into "Step 1 of 3 · Services".
    func testNarrowFoldsRail() async throws {
        XCTAssertTrue(CompanySetupPage.foldsRail(width: 420))
        XCTAssertFalse(CompanySetupPage.foldsRail(width: 520))
        XCTAssertFalse(CompanySetupPage.foldsRail(width: 720))
        XCTAssertFalse(CompanySetupPage.foldsRail(width: 0), "not measured yet: the full layout")

        let (model, _) = await opened()
        let narrow = CompanySetupPage(model: model, actions: CompanySetupActions(), layout: .narrow)
        XCTAssertNoThrow(try narrow.inspect().find(text: "Step 1 of 3 · Services"))
        XCTAssertThrowsError(try narrow.inspect().find(CompanySetupRail.self))

        let wide = CompanySetupPage(model: model, actions: CompanySetupActions(), layout: .wide)
        XCTAssertNoThrow(try wide.inspect().find(CompanySetupRail.self))
        XCTAssertThrowsError(try wide.inspect().find(text: "Step 1 of 3 · Services"))
    }

    /// The prominent button is the model's `primary`, and pressing it runs `next()`.
    func testPrimaryButtonIsTheModels() async throws {
        let (model, _) = await opened()
        let page = CompanySetupPage(model: model, actions: CompanySetupActions(), layout: .wide)
        XCTAssertTrue(try page.inspect().find(button: Model.continueTitle).isDisabled(), "nothing ticked")
        model.toggle(.google)
        try page.inspect().find(button: Model.continueTitle).tap()
        await untilObserved { model.current == .vendor(.google) }
        XCTAssertEqual(model.current, .vendor(.google))
    }

    /// ‹ Connections and Quick Connections go through the host's actions.
    func testBackAndQuickConnectionsAreTheHosts() async throws {
        let (model, _) = await opened()
        var back = 0
        var quick = 0
        let page = CompanySetupPage(model: model, actions: CompanySetupActions(
            back: { back += 1 }, openQuickConnections: { quick += 1 }), layout: .wide)
        try page.inspect().find(button: Model.backToConnections).tap()
        try page.inspect().find(button: CompanyVendorGuide.openQuickConnections).tap()
        XCTAssertEqual(back, 1)
        XCTAssertEqual(quick, 1)
    }

    /// A draft that cannot be read: the problem and Try again, never the steps.
    func testReadFailureOffersTryAgain() async throws {
        let cli = CompanyScriptedCLI()
        cli.on(["company", "draft", "show"], [], exit: 1)
        let model = Model(streamer: cli, slack: SlackAppSetupModel(streamer: cli, mode: .wizard))
        await model.open()
        let page = CompanySetupPage(model: model, actions: CompanySetupActions(), layout: .wide)
        XCTAssertNoThrow(try page.inspect().find(text: Model.draftReadFailed))
        XCTAssertThrowsError(try page.inspect().find(CompanySetupRail.self))
        try page.inspect().find(button: Model.tryAgainTitle).tap()
        await untilObserved { model.load == .ready }
        XCTAssertEqual(model.current, .services)
    }
}

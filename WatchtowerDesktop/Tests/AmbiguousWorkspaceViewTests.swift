import XCTest
import SwiftUI
import ViewInspector
import WatchtowerCore
@testable import WatchtowerDesktop

/// With several workspace databases and no `active_workspace`, launch shows
/// `AmbiguousWorkspaceView` instead of the app: the candidates, the command
/// that picks one, and a retry once the owner has run it.
@MainActor
final class AmbiguousWorkspaceViewTests: XCTestCase {
    func testNamesTheCandidatesAndTheFix() throws {
        let view = AmbiguousWorkspaceView(candidates: ["alpha", "zenith"]) {}

        XCTAssertNoThrow(try view.inspect().find(text: "alpha, zenith"))
        XCTAssertNoThrow(try view.inspect().find(text: "watchtower config set active_workspace <name>"))
    }

    func testTryAgainRetries() throws {
        var retried = false
        let view = AmbiguousWorkspaceView(candidates: ["alpha", "zenith"]) { retried = true }

        try view.inspect().find(button: "Try Again").tap()
        XCTAssertTrue(retried)
    }

    /// The ambiguous screen wins over onboarding and the app, never over the
    /// splash — swapping the branches would send the owner into onboarding
    /// with no database to onboard into.
    func testRootPrefersAmbiguousWorkspaceOverOnboarding() {
        let two = ["alpha", "zenith"]
        XCTAssertEqual(NavigationRoot.screen(isLoading: true, ambiguousWorkspaces: two, needsOnboarding: true), .splash)
        XCTAssertEqual(
            NavigationRoot.screen(isLoading: false, ambiguousWorkspaces: two, needsOnboarding: true), .ambiguousWorkspace
        )
        XCTAssertEqual(
            NavigationRoot.screen(isLoading: false, ambiguousWorkspaces: two, needsOnboarding: false), .ambiguousWorkspace
        )
        XCTAssertEqual(NavigationRoot.screen(isLoading: false, ambiguousWorkspaces: [], needsOnboarding: true), .onboarding)
        XCTAssertEqual(NavigationRoot.screen(isLoading: false, ambiguousWorkspaces: [], needsOnboarding: false), .main)
    }
}

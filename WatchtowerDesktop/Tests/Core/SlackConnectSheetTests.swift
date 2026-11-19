import XCTest
@testable import WatchtowerCore

/// Every string of the connect sheet (screens spec §4.3) per step.
final class SlackConnectSheetTests: XCTestCase {
    private let target = SlackConnectTarget(teamID: "T0ACME", clientID: "1111.2222")

    /// The confirm carries the LLM-provider disclosure and the privacy link
    /// (policy hygiene #1769; reference shot `slack-ph-connectDisclosure`).
    func testConfirmShowsDisclosureLine() throws {
        let sheet = try XCTUnwrap(SlackConnectSheetContent(step: .confirming(flow: "f1", target: target)))
        XCTAssertEqual(sheet.title, "Connect a Slack workspace?")
        XCTAssertEqual(sheet.body, "A link asks Watchtower to connect workspace T0ACME through app 1111.2222. "
            + "Connect only if you opened this link yourself.")
        XCTAssertEqual(sheet.disclosure, SlackDisclosureCopy.connectLine(workspace: "T0ACME"))
        XCTAssertEqual(sheet.privacyLink, "Privacy policy")
        XCTAssertEqual(sheet.privacyURL, SlackDisclosureCopy.privacyURL)
        XCTAssertNil(sheet.icon)
        XCTAssertEqual(sheet.buttons.map(\.title), ["Cancel", "Connect"])
        XCTAssertEqual(sheet.buttons.filter(\.isPrimary).map(\.action), [.connect])
    }

    func testBrowserStep() throws {
        for step in [SlackConnectFlowModel.Step.starting(target), .browser(flow: "f1", target: target, since: Date())] {
            let sheet = try XCTUnwrap(SlackConnectSheetContent(step: step))
            XCTAssertEqual(sheet.icon, .progress)
            XCTAssertNil(sheet.title)
            XCTAssertEqual(sheet.body, "Finish in your browser: Slack asks you to allow Watchtower.")
            XCTAssertEqual(sheet.note, "If Slack says your admin must approve the app, connect again once they have.")
            XCTAssertNil(sheet.disclosure)
            XCTAssertNil(sheet.privacyLink)
            XCTAssertEqual(sheet.buttons.map(\.title), ["Cancel"])
        }
    }

    func testConnectedStep() throws {
        let sheet = try XCTUnwrap(SlackConnectSheetContent(step: .connected(workspace: "acme")))
        XCTAssertEqual(sheet.icon, .success)
        XCTAssertEqual(sheet.title, "Connected to acme")
        XCTAssertEqual(sheet.body, "The first sync starts now. Digests and the Inbox fill in after it.")
        XCTAssertEqual(sheet.buttons.map(\.title), ["Done"])
        XCTAssertEqual(sheet.buttons.map(\.isPrimary), [true])
    }

    func testFailedSteps() throws {
        let cases: [(SlackConnectFlowModel.Failure, SlackConnectSheetContent.Icon, String)] = [
            (.teamMismatch, .warning,
             "Slack signed you in to a different workspace than the link names. Nothing was saved."),
            (.denied, .denied, "You did not allow Watchtower in Slack. Nothing was saved."),
            (.other("the exchange failed"), .warning, "Could not connect: the exchange failed. Nothing was saved.")
        ]
        for (failure, icon, body) in cases {
            let sheet = try XCTUnwrap(SlackConnectSheetContent(step: .failed(failure, retry: target)))
            XCTAssertEqual(sheet.icon, icon)
            XCTAssertNil(sheet.title)
            XCTAssertEqual(sheet.body, body)
            XCTAssertEqual(sheet.buttons.map(\.title), ["Close", "Start again"])
            XCTAssertEqual(sheet.buttons.filter(\.isPrimary).map(\.action), [.startAgain])
        }
        XCTAssertNil(SlackConnectSheetContent(step: .idle))
    }
}

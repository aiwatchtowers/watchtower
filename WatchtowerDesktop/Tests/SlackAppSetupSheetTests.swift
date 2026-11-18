import SwiftUI
import ViewInspector
import WatchtowerCore
import XCTest
@testable import WatchtowerDesktop

/// The real setup sheet: the Slack data disclosure (#1769) above the token
/// field, and the model's strings equal to the approved mockups' copy.
@MainActor
final class SlackAppSetupSheetTests: XCTestCase {
    private typealias Model = SlackAppSetupModel
    private typealias Copy = SlackFullLiveMockCopy

    private func texts(_ view: some View) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    func testShowsDisclosureBeforeTokenField() throws {
        let sheet = SlackAppSetupSheet(model: Model(streamer: nil))
        let shown = try texts(sheet)
        let title = try XCTUnwrap(shown.firstIndex(of: SlackDisclosureCopy.setupTitle))
        let step2 = try XCTUnwrap(shown.firstIndex(of: Model.step2Title), "the step that holds the token field")
        XCTAssertLessThan(title, step2)
        for line in SlackDisclosureCopy.setupLines {
            let index = try XCTUnwrap(shown.firstIndex(of: line), line)
            XCTAssertLessThan(index, step2, line)
        }
        XCTAssertNoThrow(try sheet.inspect().find(button: SlackDisclosureCopy.privacyLink))
        XCTAssertNoThrow(try sheet.inspect().find(ViewType.SecureField.self))
    }

    func testAddLinkSheetHasNoDisclosure() throws {
        let sheet = SlackAppSetupSheet(model: SlackSetupShotFixture.model(.addLinkEmpty))
        XCTAssertFalse(try texts(sheet).contains(SlackDisclosureCopy.setupTitle))
    }

    /// The shipped strings say what the approved mockups said (`acme`).
    func testStringsMatchTheMockups() {
        XCTAssertEqual(Model.setupTitle, Copy.setupTitle)
        XCTAssertEqual(Model.setupIntro, Copy.setupIntro)
        XCTAssertEqual(Model.step1Title, Copy.setupStep1)
        XCTAssertEqual(Model.step1Help, Copy.setupStep1Help)
        XCTAssertEqual(Model.openTokenPage, Copy.openTokenPage)
        XCTAssertEqual(Model.step2Title, Copy.setupStep2)
        XCTAssertEqual(Model.tokenPlaceholder, Copy.tokenPlaceholder)
        XCTAssertEqual(Model.tokenNote, Copy.tokenNote)
        XCTAssertEqual(Model.createSteps.map(\.label), Copy.progressSteps)
        XCTAssertEqual(Model.progressCaption, Copy.progressCaption)
        XCTAssertEqual(Model.successTitle("acme"), Copy.successTitle)
        XCTAssertEqual(Model.successBody, Copy.successBody)
        XCTAssertEqual(Model.badTokenBody, Copy.badToken)
        XCTAssertEqual(Model.notAllowedBody, Copy.notAllowed)
        XCTAssertEqual(Model.linkFailedBody, Copy.linkFailed)
        XCTAssertEqual(Model.approvalBody, Copy.approval)
        XCTAssertEqual(Model.addLinkBusy, Copy.addLinkBusy)
        XCTAssertEqual(Model.linkDoneBody, Copy.addLinkDone)
        XCTAssertEqual(Model.adoptTitle("acme"), Copy.adoptTitle)
        XCTAssertEqual(Model.adoptBody, Copy.adoptBody)
        XCTAssertEqual(Model.appIDLabel, Copy.adoptAppIDLabel)
        XCTAssertEqual(Model.appIDHelp, Copy.adoptAppIDHelp)
        XCTAssertEqual(Model.notCollaboratorBody, Copy.notCollaborator)
        XCTAssertEqual(Model.adminNote(workspace: "acme"), Copy.adminNote)
        XCTAssertEqual(Model.adminNoteCopiedLine, Copy.adminNoteCopied)
        XCTAssertEqual(Model.installLine("acme"), Copy.recordInstall)
        let labels: [(Model.Action, String)] = [
            (.create, Copy.createApp), (.cancel, Copy.cancel), (.close, Copy.close), (.done, Copy.done),
            (.copyCode, Copy.copyCode), (.tryAgain, Copy.tryAgain), (.copyAdminNote, Copy.copyAdminNote),
            (.updateApp, Copy.adoptAction), (.showAddLink, Copy.addLink), (.addLink, Copy.addLinkAction),
            (.continueSetup, Copy.continueSetup), (.checkAgain, Copy.checkAgain)
        ]
        for (action, label) in labels { XCTAssertEqual(Model.label(action), label) }
        let add = SlackSetupShotFixture.model(.addLinkEmpty)
        XCTAssertEqual(add.title, Copy.addLinkTitle)
        XCTAssertEqual(add.intro, Copy.addLinkIntro)
    }

    func testRecordRowsMatchTheMockups() {
        XCTAssertEqual(SlackSetupShotFixture.rowsModel(.setupInstall).recordRows.map(\.text), [Copy.recordInstall])
        XCTAssertEqual(SlackSetupShotFixture.rowsModel(.setupApproval).recordRows.map(\.text), [Copy.recordApproval])
        XCTAssertEqual(SlackSetupShotFixture.rowsModel(.linkMissing).recordRows.map(\.text), [Copy.recordLinkMissing])
        XCTAssertTrue(SlackSetupShotFixture.rowsModel(.full).recordRows.isEmpty)
    }
}

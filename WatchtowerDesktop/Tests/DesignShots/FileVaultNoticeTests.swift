import XCTest
@testable import WatchtowerCore

/// The FileVault copy equals the mockups' string table (it lives in this
/// test target, so the comparison does too).
final class FileVaultNoticeTests: XCTestCase {
    func testCopy() {
        XCTAssertEqual(FileVaultNotice.text, SlackPolicyMockCopy.fileVaultOff)
        XCTAssertEqual(FileVaultNotice.action, SlackPolicyMockCopy.openFileVault)
        XCTAssertEqual(FileVaultNotice.settingsURL,
                       "x-apple.systempreferences:com.apple.preference.security?FileVault")
    }

    func testShownOnlyWhenOff() {
        XCTAssertTrue(FileVaultNotice.isShown(.off))
        XCTAssertFalse(FileVaultNotice.isShown(.on))
        XCTAssertFalse(FileVaultNotice.isShown(.unknown))
    }
}

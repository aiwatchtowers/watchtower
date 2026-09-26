import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop

@MainActor
final class AddRuleSheetViewTests: XCTestCase {

    /// Все четыре scope-варианта присутствуют в Picker'е.
    func testAllScopeOptionsRendered() throws {
        let view = AddRuleSheet { _, _, _ in }
        for label in ["Sender", "Channel", "Jira label", "Trigger"] {
            XCTAssertNoThrow(try view.inspect().find(text: label),
                             "scope option '\(label)' must be visible")
        }
    }

    /// Все четыре rule-варианта присутствуют.
    func testAllRuleOptionsRendered() throws {
        let view = AddRuleSheet { _, _, _ in }
        for label in ["Mute", "Boost", "Downgrade class", "Boost trigger"] {
            XCTAssertNoThrow(try view.inspect().find(text: label),
                             "rule option '\(label)' must be visible")
        }
    }

    /// Кнопка Save вызывает onSave с дефолтными значениями
    /// scope=sender:, weight=-0.8, type=source_mute.
    func testSaveDispatchesDefaults() async throws {
        let exp = expectation(description: "onSave called")
        var got: (scope: String, weight: Double, type: String)?

        let view = AddRuleSheet { scope, weight, type in
            got = (scope, weight, type)
            exp.fulfill()
        }

        try view.inspect().find(button: "Save").tap()
        await fulfillment(of: [exp], timeout: 1.0)

        XCTAssertEqual(got?.scope, "sender:")
        XCTAssertEqual(got?.weight ?? 0, -0.8, accuracy: 0.0001)
        XCTAssertEqual(got?.type, "source_mute")
    }
}

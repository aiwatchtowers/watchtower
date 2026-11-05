import XCTest
@testable import WatchtowerDesktop
@testable import WatchtowerCore

/// The Inbox's press addresses against Go's shared fixture
/// (`internal/automations/blocks/testdata/blocks_cases.json`, plan Task 13):
/// for every Go-canonical document, the index a drawn button sends to
/// `automations reply --action` names the action Go's `FlattenActions` puts
/// there, the card's own actions read from the stored `card_actions`.
final class ArtifactFixtureParityTests: XCTestCase {
    private struct GoCase {
        let name: String
        let canonical: String
        /// The card's own actions as `automation_outputs.actions_json` stores them.
        let cardActions: String
        let labels: [String]
    }

    private func goCases() throws -> [GoCase] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/automations/blocks/testdata/blocks_cases.json")
        let fixture = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let valid = try XCTUnwrap(fixture["valid"] as? [[String: Any]])
        return try valid.map { item in
            GoCase(
                name: try XCTUnwrap(item["name"] as? String),
                canonical: try XCTUnwrap(item["canonical"] as? String),
                cardActions: try XCTUnwrap(item["card_actions"] as? String),
                labels: try XCTUnwrap(item["actions"] as? [String])
            )
        }
    }

    private func card(_ goCase: GoCase) -> AutomationOutputCard {
        AutomationOutputCard(
            id: 1, automationID: 1, automationName: "Digest", runID: 1, title: "Digest", body: "",
            priority: "medium", createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            actionsJSON: goCase.cardActions, blocksJSON: goCase.canonical, outputKey: nil, contentHash: "h")
    }

    func testPressIndexNamesGoFlattenedAction() throws {
        let cases = try goCases()
        XCTAssertGreaterThanOrEqual(cases.count, 10)
        var pressed = 0
        for goCase in cases {
            let layout = InboxCardLayout.of(card(goCase))
            guard case .artifact(.document, _) = layout else {
                XCTFail("\(goCase.name): Go's canonical document is not drawn as blocks")
                continue
            }
            for action in layout.pressable {
                XCTAssertTrue(goCase.labels.indices.contains(action.index), "\(goCase.name) index \(action.index)")
                guard goCase.labels.indices.contains(action.index) else { continue }
                XCTAssertEqual(action.label, goCase.labels[action.index], "\(goCase.name) index \(action.index)")
                pressed += 1
            }
        }
        // Every kind but `target` is pressed from the Inbox (Task 15 wires it).
        XCTAssertGreaterThanOrEqual(pressed, 16)
    }
}

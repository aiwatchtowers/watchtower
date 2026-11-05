import XCTest
@testable import WatchtowerDesktop
@testable import WatchtowerCore

/// The Inbox's press addresses against Go's shared fixture
/// (`internal/automations/blocks/testdata/blocks_cases.json`, plan Task 13):
/// for every Go-canonical document, the index a drawn button sends to
/// `automations reply --action` names the action Go's `FlattenActions` puts
/// there. The fixture keeps a card's own actions only as script input, so
/// they are stood in for by chat buttons with the same labels; what is
/// checked is that the block buttons come after them, in Go's order.
final class ArtifactFixtureParityTests: XCTestCase {
    private struct GoCase {
        let name: String
        let canonical: String
        let cardLabels: [String]
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
            let input = try XCTUnwrap(item["input"] as? [String: Any])
            return GoCase(
                name: try XCTUnwrap(item["name"] as? String),
                canonical: try XCTUnwrap(item["canonical"] as? String),
                cardLabels: (input["actions"] as? [[String: Any]] ?? []).map { $0["label"] as? String ?? "" },
                labels: try XCTUnwrap(item["actions"] as? [String])
            )
        }
    }

    private func card(_ goCase: GoCase) throws -> AutomationOutputCard {
        let stand = goCase.cardLabels.map { ["label": $0, "kind": "chat", "chat": "x"] }
        let actions = try XCTUnwrap(String(bytes: try JSONSerialization.data(withJSONObject: stand), encoding: .utf8))
        return AutomationOutputCard(
            id: 1, automationID: 1, automationName: "Digest", runID: 1, title: "Digest", body: "",
            priority: "medium", createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            actionsJSON: actions, blocksJSON: goCase.canonical, outputKey: nil, contentHash: "h")
    }

    func testPressIndexNamesGoFlattenedAction() throws {
        let cases = try goCases()
        XCTAssertGreaterThanOrEqual(cases.count, 10)
        var pressed = 0
        for goCase in cases {
            let layout = InboxCardLayout.of(try card(goCase))
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

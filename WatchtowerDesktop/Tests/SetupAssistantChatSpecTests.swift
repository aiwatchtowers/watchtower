import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// Setup assistants get no owner-instruction slot and no remember command
/// (spec 2026-10-23): their turns never carry `--owner-instructions`.
@MainActor
final class SetupAssistantChatSpecTests: XCTestCase {
    func testSetupAssistantSpecHasNoOwnerInstructions() {
        let chat = SetupAssistantChat<Int, Int>(
            contextID: "t", greeting: "hi", systemPrompt: "S", connectionErrorLead: "",
            formStateBlock: { _ in "" }, parse: { ($0, nil, false) }, aiService: nil, gate: nil
        )
        XCTAssertFalse(chat.engine.spec.ownerInstructions)
        XCTAssertEqual(chat.engine.spec.persistence, .memory)
    }
}

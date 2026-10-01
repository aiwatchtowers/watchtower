import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The onboarding interview on the shared embedded chat component: the
/// `[READY]` marker, the questionnaire's local bubbles, the hidden opening
/// prompt and its retry.
@MainActor
final class OnboardingChatEngineTests: XCTestCase {
    private func vm(_ ai: any AIServiceProtocol) -> OnboardingChatViewModel {
        OnboardingChatViewModel(aiService: ai, dbManager: nil)
    }

    private func finish(_ vm: OnboardingChatViewModel) async {
        let done = await waitForCondition { !vm.isStreaming }
        XCTAssertTrue(done)
    }

    func testReadyMarkerIsStrippedInAnyCaseAndOpensContinue() async {
        let vm = vm(MockClaudeService(events: [.text("Thanks, that's all I need. [ready]"), .done]))
        vm.inputText = "I run the platform team"
        vm.send()
        await finish(vm)
        XCTAssertTrue(vm.chatReady)
        XCTAssertEqual(vm.messages.last?.text, "Thanks, that's all I need.")
    }

    func testAReplyWithoutAQuestionAfterSixAnswersIsReady() async {
        let replies = (0..<6).map { index -> [StreamEvent] in
            index < 5 ? [.text("And what else?"), .done] : [.text("Here is your summary."), .done]
        }
        let vm = vm(MockClaudeService(eventSequence: replies))
        for index in 0..<6 {
            vm.inputText = "answer \(index)"
            vm.send()
            await finish(vm)
            XCTAssertEqual(vm.chatReady, index == 5, "after answer \(index)")
        }
    }

    func testTheQuestionnaireIsLocalAndTheOpeningPromptHidden() async {
        let mock = MockClaudeService(events: [.text("Hi! Which team are you on?"), .done])
        let vm = vm(mock)
        vm.startQuestionnaire()
        XCTAssertEqual(vm.messages.map(\.role), [.assistant])
        XCTAssertTrue(mock.prompts.isEmpty, "the questionnaire never calls the AI")
        vm.quickReplies.first?.action()  // "Yes, people report to me"
        vm.quickReplies.last?.action()   // finishes the questionnaire → opening prompt
        await finish(vm)
        XCTAssertEqual(mock.prompts.count, 1)
        XCTAssertTrue(mock.prompts[0].contains("completed the role questionnaire"))
        XCTAssertFalse(vm.messages.contains { $0.text.contains("completed the role questionnaire") },
                       "the opening prompt has no visible row")
        XCTAssertEqual(vm.messages.last?.text, "Hi! Which team are you on?")
    }

    func testRetryOfTheHiddenOpeningPromptAddsNoOwnerRow() async {
        let mock = MockClaudeService(error: WatchtowerAIError.cliNotFound)
        let vm = vm(mock)
        vm.initiateChat()
        await finish(vm)
        XCTAssertNotNil(vm.errorMessage)
        vm.retryAfterError()
        await finish(vm)
        XCTAssertEqual(mock.prompts.count, 2)
        XCTAssertEqual(mock.prompts[0], mock.prompts[1])
        XCTAssertFalse(vm.messages.contains { $0.role == .user })
        XCTAssertEqual(vm.messages.filter { $0.role == .assistant }.count, 1, "the failed bubble is replaced")
    }

    /// The profile prompt reads the interview rows (an error line from the
    /// generation itself throws and falls back to the local summary).
    func testTheProfilePromptReadsTheInterview() async {
        let mock = MockClaudeService(eventSequence: [
            [.text("Got it."), .done],
            [.error("not logged in"), .done]
        ])
        let vm = vm(mock)
        vm.inputText = "I lead payments"
        vm.send()
        await finish(vm)
        vm.role = "Engineering Manager"
        await vm.generatePromptContext()
        XCTAssertTrue(mock.prompts.last?.contains("USER: I lead payments") ?? false)
        XCTAssertTrue(mock.prompts.last?.contains("ASSISTANT: Got it.") ?? false)
    }
}

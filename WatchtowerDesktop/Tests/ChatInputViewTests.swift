import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop

@MainActor
final class ChatInputViewTests: XCTestCase {

    // MARK: - Helpers

    private func makeView(
        text: String = "",
        isStreaming: Bool = false,
        onSend: @escaping () -> Void = {},
        onStop: (() -> Void)? = nil,
        placeholder: String = "Ask about your workspace...",
        dictationTargetID: String? = nil
    ) -> ChatInput {
        var stored = text
        return ChatInput(
            text: Binding(get: { stored }, set: { stored = $0 }),
            isStreaming: isStreaming,
            onSend: onSend,
            onStop: onStop,
            placeholder: placeholder,
            dictationTargetID: dictationTargetID
        )
    }

    private func hasMicButton(_ view: ChatInput) throws -> Bool {
        (try? view.inspect().find(ViewType.Image.self) { try $0.actualImage().name() == "mic.fill" }) != nil
    }

    // MARK: - Tests

    /// Пустой text → виден placeholder.
    func testPlaceholderShownWhenEmpty() throws {
        let view = makeView(text: "", placeholder: "Type here…")
        XCTAssertNoThrow(try view.inspect().find(text: "Type here…"))
    }

    /// Непустой text → placeholder в дерево не вставляется.
    func testPlaceholderHiddenWhenTextPresent() throws {
        let view = makeView(text: "hello", placeholder: "Type here…")
        XCTAssertThrowsError(try view.inspect().find(text: "Type here…"))
    }

    /// Не streaming + пустой text → кнопка отключена.
    func testSendButtonDisabledWhenTextEmpty() throws {
        let view = makeView(text: "", isStreaming: false)
        let button = try view.inspect().find(ViewType.Button.self)
        XCTAssertTrue(try button.isDisabled())
    }

    /// Не streaming + непустой text → кнопка активна, тап вызывает onSend.
    func testSendButtonInvokesOnSendWhenTextPresent() throws {
        var sent = 0
        let view = makeView(text: "hi", isStreaming: false, onSend: { sent += 1 })

        let button = try view.inspect().find(ViewType.Button.self)
        XCTAssertFalse(try button.isDisabled())
        try button.tap()

        XCTAssertEqual(sent, 1)
    }

    /// Streaming + onStop=nil → кнопка отключена, onSend не вызывается.
    func testStreamingWithoutOnStopDisablesButton() throws {
        var sent = 0
        let view = makeView(text: "x", isStreaming: true, onSend: { sent += 1 }, onStop: nil)

        let button = try view.inspect().find(ViewType.Button.self)
        XCTAssertTrue(try button.isDisabled())
        XCTAssertEqual(sent, 0)
    }

    /// Streaming + onStop задан → тап вызывает onStop, не onSend.
    func testStreamingWithOnStopInvokesOnStop() throws {
        var sent = 0
        var stopped = 0
        let view = makeView(
            text: "anything",
            isStreaming: true,
            onSend: { sent += 1 },
            onStop: { stopped += 1 }
        )

        try view.inspect().find(ViewType.Button.self).tap()

        XCTAssertEqual(stopped, 1)
        XCTAssertEqual(sent, 0)
    }

    // MARK: - Dictation mic button

    /// dictationTargetID nil (the default) → no mic button, regardless of environment.
    func testNoMicButtonWhenDictationTargetIDNil() throws {
        let view = makeView(dictationTargetID: nil)
        XCTAssertFalse(try hasMicButton(view))
    }

    /// dictationTargetID set but no DictationCenter in the environment (the
    /// test-harness default) → still no mic button — DictationButton itself
    /// renders nothing without a center, but ChatInput's own guard should
    /// already keep it out of the hierarchy.
    func testNoMicButtonWhenDictationCenterAbsentFromEnvironment() throws {
        let view = makeView(dictationTargetID: "chat.workspace")
        XCTAssertFalse(try hasMicButton(view))
    }

    /// The positive control for the two guards above: targetID set AND a
    /// DictationCenter present → the mic button IS in the hierarchy. Driven
    /// through `ChatInputContent` (the plain view `ChatInput` renders) with
    /// an explicit center — ViewInspector cannot inject custom `@Environment`
    /// values (the `TrayMenuContent` precedent).
    func testMicButtonShownWhenTargetIDSetAndCenterPresent() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ChatInputViewTests-\(UUID().uuidString)"))
        // Pin the whisper lane (absent key → Apple on macOS 26) so the
        // center stays on the injectable engineFactory path.
        defaults.set("small", forKey: DictationEngineChoice.defaultsKey)
        let center = DictationCenter(
            recorderFactory: { FakeMicRecorder() },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: []), supportsLive: true) },
            runnerResolver: { nil },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )
        var stored = ""
        let view = ChatInputContent(
            text: Binding(get: { stored }, set: { stored = $0 }),
            isStreaming: false,
            onSend: {},
            onStop: nil,
            placeholder: "Type here…",
            dictationTargetID: "chat.workspace",
            dictationCenter: center
        )
        let found = (try? view.inspect().find(ViewType.Image.self) {
            try $0.actualImage().name() == "mic.fill"
        }) != nil
        XCTAssertTrue(found, "with a target id and a center, the mic button must render")
    }
}

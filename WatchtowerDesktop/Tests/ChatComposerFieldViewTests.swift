import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class ChatComposerFieldViewTests: XCTestCase {

    // MARK: - Helpers

    private func makeView(
        text: String = "",
        isStreaming: Bool = false,
        onSend: @escaping () -> Void = {},
        onStop: (() -> Void)? = nil,
        placeholder: String = "Ask about your workspace...",
        dictationTargetID: String? = nil
    ) -> ChatComposerField {
        var stored = text
        return ChatComposerField(
            text: Binding(get: { stored }, set: { stored = $0 }),
            isStreaming: isStreaming,
            onSend: onSend,
            onStop: onStop,
            placeholder: placeholder,
            dictationTargetID: dictationTargetID
        )
    }

    private func hasMicButton(_ view: ChatComposerField) throws -> Bool {
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
        let view = makeView(text: "hi", isStreaming: false) { sent += 1 }

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
    /// renders nothing without a center, but ChatComposerField's own guard should
    /// already keep it out of the hierarchy.
    func testNoMicButtonWhenDictationCenterAbsentFromEnvironment() throws {
        let view = makeView(dictationTargetID: "chat.workspace")
        XCTAssertFalse(try hasMicButton(view))
    }

    /// The positive control for the two guards above: targetID set AND a
    /// DictationCenter present → the mic button IS in the hierarchy. Driven
    /// through `ChatComposerFieldContent` (the plain view `ChatComposerField` renders) with
    /// an explicit center — ViewInspector cannot inject custom `@Environment`
    /// values (the `TrayMenuContent` precedent).
    func testMicButtonShownWhenTargetIDSetAndCenterPresent() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ChatComposerFieldViewTests-\(UUID().uuidString)"))
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
        let view = ChatComposerFieldContent(
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

    /// A pending quote batch is sendable content even with an empty field.
    func testPendingContentEnablesSendWithEmptyText() throws {
        var sent = 0
        var stored = ""
        let view = ChatComposerField(text: Binding(get: { stored }, set: { stored = $0 }), isStreaming: false,
                                     onSend: { sent += 1 }, hasPendingContent: true)
        let button = try view.inspect().find(ViewType.Button.self)
        XCTAssertFalse(try button.isDisabled())
        try button.tap()
        XCTAssertEqual(sent, 1)
    }
}

extension ChatComposerFieldViewTests {
    /// U1: with a provider that reads no images or PDFs the paperclip stays
    /// enabled (text files still attach), its help naming the reason; the
    /// test keeps its old name from the plan.
    func testAttachDisabledWithReasonWhenNoImages() throws {
        let reason = try XCTUnwrap(ProviderCapabilities.none.attachUnavailableReason)
        XCTAssertEqual(reason, "Images and PDFs need a provider that reads them.")
        var stored = ""
        let off = ChatComposerField(text: Binding(get: { stored }, set: { stored = $0 }), isStreaming: false,
                                    onSend: {}, placeholder: "Ask", onAttachFiles: { _ in },
                                    attachUnavailableReason: reason)
        let clip = try off.inspect().find(ViewType.Button.self) { try $0.accessibilityLabel().string() == "Attach files" }
        XCTAssertFalse(try clip.isDisabled(), "text files still attach")
        XCTAssertEqual(try clip.help().string(), "Attach text files. " + reason)

        let on = ChatComposerField(text: Binding(get: { stored }, set: { stored = $0 }), isStreaming: false,
                                   onSend: {}, placeholder: "Ask", onAttachFiles: { _ in }, attachUnavailableReason: nil)
        let enabled = try on.inspect().find(ViewType.Button.self) { try $0.accessibilityLabel().string() == "Attach files" }
        XCTAssertFalse(try enabled.isDisabled())
        XCTAssertTrue(ChatComposerFieldContent.isBinary(URL(fileURLWithPath: "/tmp/a.png")))
        XCTAssertTrue(ChatComposerFieldContent.isBinary(URL(fileURLWithPath: "/tmp/a.pdf")))
        XCTAssertFalse(ChatComposerFieldContent.isBinary(URL(fileURLWithPath: "/tmp/a.csv")))
    }

    /// F8: an images-only provider (Codex) refuses a PDF at drop, paste and
    /// pick, with its own reason; images still attach. A provider with no
    /// binary attachments refuses both with U1's reason.
    func testImagesOnlyProviderRefusesPDFs() throws {
        let codex = AIModelCatalog(providers: ProviderCatalogFixture.providers()).capabilities(for: "codex")
        let pdfReason = try XCTUnwrap(codex.pdfUnavailableReason)
        let pdf = ChatComposerFieldContent.kind(URL(fileURLWithPath: "/tmp/a.pdf"))
        let png = ChatComposerFieldContent.kind(URL(fileURLWithPath: "/tmp/a.png"))
        XCTAssertEqual(pdf, .pdf)
        XCTAssertEqual(png, .image)
        XCTAssertEqual(ChatComposerFieldContent.refusal(of: pdf, attach: nil, pdf: pdfReason), pdfReason)
        XCTAssertNil(ChatComposerFieldContent.refusal(of: png, attach: nil, pdf: pdfReason))
        XCTAssertNil(ChatComposerFieldContent.refusal(of: nil, attach: "no", pdf: pdfReason), "text files attach")
        XCTAssertEqual(ChatComposerFieldContent.refusal(of: png, attach: "U1", pdf: nil), "U1")
        XCTAssertEqual(ChatComposerFieldContent.refusal(of: pdf, attach: "U1", pdf: nil), "U1")

        var stored = ""
        let field = ChatComposerField(text: Binding(get: { stored }, set: { stored = $0 }), isStreaming: false,
                                      onSend: {}, placeholder: "Ask", onAttachFiles: { _ in },
                                      pdfUnavailableReason: pdfReason)
        let clip = try field.inspect().find(ViewType.Button.self) { try $0.accessibilityLabel().string() == "Attach files" }
        XCTAssertEqual(try clip.help().string(), "Attach images or text files. " + pdfReason)
    }
}

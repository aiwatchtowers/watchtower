import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
@testable import WatchtowerCore // memberwise init of the package struct ChatAttachment (TrayMenuViewTests precedent)

@MainActor
final class ChatComposerFieldAttachmentTests: XCTestCase {
    private func attachment(id: Int64, name: String, mime: String) -> ChatAttachment {
        ChatAttachment(id: id, conversationID: 1, projectID: nil, messageID: nil, name: name, mime: mime,
                       size: 1, path: "/tmp/\(name)", sha256: "x", createdAt: 0)
    }

    private func makeView(
        text: String = "",
        attachments: [ChatAttachment] = [],
        error: String? = nil,
        onSend: @escaping () -> Void = {},
        onAttach: (([URL]) -> Void)? = { _ in },
        onRemove: ((Int64) -> Void)? = { _ in }
    ) -> ChatComposerFieldContent {
        var stored = text
        return ChatComposerFieldContent(
            text: Binding(get: { stored }, set: { stored = $0 }),
            isStreaming: false, onSend: onSend, onStop: nil,
            placeholder: "Ask…", dictationTargetID: nil, dictationCenter: nil,
            attachments: attachments, attachmentError: error,
            onAttachFiles: onAttach, onPasteImage: nil, onRemoveAttachment: onRemove)
    }

    func testChipsShowNamesAndRemoveCallsBack() throws {
        var removed: Int64?
        let view = makeView(attachments: [attachment(id: 7, name: "shot.png", mime: "image/png")]) { removed = $0 }
        XCTAssertNoThrow(try view.inspect().find(text: "shot.png"))
        try view.inspect().find(ViewType.Button.self) { try $0.accessibilityLabel().string() == "Remove shot.png" }.tap()
        XCTAssertEqual(removed, 7)
    }

    func testSendEnabledWithAttachmentOnly() throws {
        var sent = 0
        // onSend isn't makeView's last parameter; a trailing closure here would bind to onRemove instead.
        // swiftlint:disable:next trailing_closure
        let view = makeView(attachments: [attachment(id: 1, name: "a.pdf", mime: "application/pdf")], onSend: { sent += 1 })
        let send = try view.inspect().find(ViewType.Button.self) { try $0.accessibilityLabel().string() == "Send" }
        XCTAssertFalse(try send.isDisabled())
        try send.tap()
        XCTAssertEqual(sent, 1)
    }

    func testRejectionTextShown() throws {
        let view = makeView(error: "a.zip: only images, PDFs and text files can be attached")
        XCTAssertNoThrow(try view.inspect().find(text: "a.zip: only images, PDFs and text files can be attached"))
    }

    func testPaperclipOnlyWhenAttachingIsWired() throws {
        let with = makeView()
        XCTAssertNoThrow(try with.inspect().find(ViewType.Button.self) { try $0.accessibilityLabel().string() == "Attach files" })
        let without = makeView(onAttach: nil)
        XCTAssertThrowsError(try without.inspect().find(ViewType.Button.self) { try $0.accessibilityLabel().string() == "Attach files" })
    }
}

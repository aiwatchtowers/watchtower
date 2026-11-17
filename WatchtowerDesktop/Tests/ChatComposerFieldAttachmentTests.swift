import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
@testable import WatchtowerCore // memberwise init of the package struct ChatAttachment (TrayMenuViewTests precedent)
@testable import ChatUI

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
    ) -> some View {
        var stored = text
        return ChatComposerField(
            text: Binding(get: { stored }, set: { stored = $0 }),
            isStreaming: false, config: ChatComposerFieldConfig(placeholder: "Ask…"), onSend: onSend, onStop: nil,
            attachments: attachments.map { ChatComposerAttachment(id: $0.id, name: $0.name, mime: $0.mime, size: $0.size) },
            attachmentError: error,
            onAttachFiles: onAttach, onPasteData: nil, onRemoveAttachment: onRemove)
            .macComposerStyle()
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

    func testLongPasteOfferButtonsCallBack() throws {
        var attached = 0
        var kept = 0
        let offer = LongPasteOffer(characterCount: 12_000, onAttach: { attached += 1 }, onKeep: { kept += 1 })
        XCTAssertNoThrow(try offer.inspect().find(text: "Long paste: \(12_000.formatted()) characters"))
        try offer.inspect().find(button: "Attach as File").tap()
        try offer.inspect().find(button: "Keep as Text").tap()
        XCTAssertEqual(attached, 1)
        XCTAssertEqual(kept, 1)
    }
}

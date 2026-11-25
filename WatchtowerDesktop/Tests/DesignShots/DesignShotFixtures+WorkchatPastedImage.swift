import AppKit
import ChatUI
import DesignKit
import SwiftUI
import WatchtowerCore
@testable import WatchtowerDesktop

/// A pasted image in the Workchat feed: the echoed owner line and the outgoing bubble show a thumbnail instead of the
/// saved file's path, a pasted file swept from disk is a chip with its name, and an image outside the attachments
/// folder (a dropped file) is a chip that is never read. The image is drawn into a temporary `workchat-attachments`
/// folder at prepare time and decoded into the thumbnail cache, so the render shows it.
@MainActor
enum WorkchatPastedImageShotFixtures {
    static let shots: [DesignShot] = [
        DesignShot(name: "workchat-pasted-image", prepare: { try await view() }, size: NSSize(width: 720, height: 640))
    ]

    private static var folder: URL?

    static func cleanUp() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }

    private static func view() async throws -> AnyView {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wt-shot-\(UUID().uuidString)")
        folder = root
        let attachments = root.appendingPathComponent("acme/workchat-attachments")
        let pastes = attachments.appendingPathComponent("7")
        try FileManager.default.createDirectory(at: pastes, withIntermediateDirectories: true)
        let echoed = pastes.appendingPathComponent("20261125-101500-1.png").path
        let sending = pastes.appendingPathComponent("20261125-102000-1.png").path
        let swept = pastes.appendingPathComponent("20261118-090000-1.png").path
        try sampleScreenshot().write(to: URL(fileURLWithPath: echoed))
        try sampleScreenshot(wide: false).write(to: URL(fileURLWithPath: sending))
        for path in [echoed, sending] {
            _ = await WorkchatThumbnailCache.load(.init(path: path, isAttachment: true))
        }

        let now = Date()
        let entries = [
            SessionFeedEntry(id: "o1", kind: "owner", at: now - 600, text: "\(swept) the old one, for comparison"),
            SessionFeedEntry(id: "a1", kind: "agent", at: now - 590, text: "That file is gone; paste it again if you need it."),
            SessionFeedEntry(id: "o3", kind: "owner", at: now - 500, text: "and the mockup\n/Users/example/Desktop/mockup.png"),
            SessionFeedEntry(id: "o2", kind: "owner", at: now - 300,
                             text: "\(echoed) the transcriber does not work\n[image]"),
            SessionFeedEntry(id: "a2", kind: "agent", at: now - 280,
                             text: "I see the error banner in the screenshot. Checking the recorder logs.")
        ]
        var feed = WorkchatFeed(entries: entries, markdown: SessionFeedMarkdownCache(), expandedEvents: []) { _ in }
        feed.attachmentsRoot = attachments.path
        var context = feed.context()
        let line = WorkchatOutgoing(id: UUID(), text: "\(sending) and this one after the fix", sentAt: now,
                                    state: .sending, typedText: "[Image #1] and this one after the fix",
                                    attachmentPaths: [sending])
        context.footer = AnyView(WorkchatOutgoingBubble(line: line, attachmentsRoot: attachments.path, onCancel: {},
                                                        onShowTerminal: {}))
        return AnyView(
            ChatUI.ChatFeedView(messages: feed.messages, context: context)
                .macChatStyle(hooks: .app, look: .workchat)
                .detailBackground()
        )
    }

    /// A made-up window screenshot: a title bar, a sidebar and a red banner on a light page.
    private static func sampleScreenshot(wide: Bool = true) throws -> Data {
        let (width, height) = wide ? (960, 600) : (600, 720)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(CGColor(gray: 0.96, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0.85, alpha: 1))
        context.fill(CGRect(x: 0, y: height - 48, width: width, height: 48))
        context.setFillColor(CGColor(gray: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 4, height: height - 48))
        context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: width / 4 + 32, y: height - 140, width: width * 3 / 4 - 64, height: 56))
        context.setFillColor(CGColor(gray: 0.75, alpha: 1))
        for row in 0..<6 {
            context.fill(CGRect(x: width / 4 + 32, y: height - 200 - row * 48, width: width / 2, height: 20))
        }
        guard let image = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return png
    }
}

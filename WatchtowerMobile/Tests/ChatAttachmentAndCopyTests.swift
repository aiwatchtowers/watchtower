import ImageIO
import UIKit
import UniformTypeIdentifiers
import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The phone's attachment rules (spec §4.5): the Mac's limits through the shared `attachment_limit_cases.json`,
/// HEIC → JPEG, images over 5 MB downsized, and the 30 MB a message carries.
final class ChatAttachmentPickerTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Case: Decodable {
            struct Expect: Decodable {
                let ok: Bool
                let mime: String?
                let ext: String?
                let reason: String?
                let limit: Int64?
                let message: String?
            }

            let name: String
            let fileName: String
            let headHex: String
            let fill: String
            let size: Int
            let expect: Expect
        }

        let cases: [Case]
    }

    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("internal/chatstore/testdata/attachment_limit_cases.json")

    private func bytes(_ item: Fixture.Case) -> Data {
        var data = Data()
        var hex = Substring(item.headHex)
        while hex.count >= 2 {
            data.append(UInt8(hex.prefix(2), radix: 16) ?? 0)
            hex = hex.dropFirst(2)
        }
        let fill = UInt8(item.fill.utf8.first ?? 0x61)
        if data.count < item.size { data.append(Data(repeating: fill, count: item.size - data.count)) }
        return data
    }

    func testTheSharedLimitCases() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let fixture = try decoder.decode(Fixture.self, from: Data(contentsOf: Self.fixture))
        XCTAssertGreaterThan(fixture.cases.count, 20)
        for item in fixture.cases {
            switch ChatAttachmentLimits.validate(data: bytes(item), fileName: item.fileName) {
            case let .success(kind):
                XCTAssertTrue(item.expect.ok, item.name)
                XCTAssertEqual(kind.mime, item.expect.mime, item.name)
                XCTAssertEqual(kind.fileExtension(fallbackName: item.fileName), item.expect.ext, item.name)
            case let .failure(rejection):
                XCTAssertFalse(item.expect.ok, item.name)
                XCTAssertEqual(rejection.reason, item.expect.reason, item.name)
                let limit = item.expect.limit.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
                XCTAssertEqual(rejection.message, item.expect.message?.replacingOccurrences(of: "{limit}", with: limit), item.name)
            }
        }
    }

    /// A square image of random pixels (nothing for a codec to squeeze), encoded as `type`.
    private func image(side: Int, type: UTType) throws -> Data {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for index in pixels.indices {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            pixels[index] = index % 4 == 3 ? 255 : UInt8(truncatingIfNeeded: seed >> 33)
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let cgImage = try XCTUnwrap(CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return out as Data
    }

    func testAHEICPhotoBecomesAJPEG() throws {
        let heic = try image(side: 64, type: .heic)
        XCTAssertTrue(ChatAttachmentPrep.isHEIF(heic))
        let prepared = try ChatAttachmentPrep.prepare(data: heic, fileName: "IMG_0001.HEIC").get()
        XCTAssertEqual(prepared.mime, "image/jpeg")
        XCTAssertEqual(prepared.name, "IMG_0001.jpg")
        XCTAssertEqual(prepared.data.prefix(3), Data([0xFF, 0xD8, 0xFF]))
    }

    func testAnImageOverFiveMegabytesIsDownsizedToFit() throws {
        let big = try image(side: 1_400, type: .png)
        XCTAssertGreaterThan(Int64(big.count), ChatAttachmentLimits.imageLimit, "the sample must start over the limit")
        let prepared = try ChatAttachmentPrep.prepare(data: big, fileName: "board.png").get()
        XCTAssertLessThanOrEqual(Int64(prepared.data.count), ChatAttachmentLimits.imageLimit)
        XCTAssertEqual(prepared.mime, "image/jpeg")
        XCTAssertEqual(prepared.name, "board.jpg")
    }

    func testAMessageCarriesAtMostThirtyMegabytesEncoded() {
        let pdf = (mime: "application/pdf", size: Int64(20 << 20))
        XCTAssertTrue(ChatAttachmentLimits.fitsMessage([pdf]))
        XCTAssertFalse(ChatAttachmentLimits.fitsMessage([pdf, (mime: "image/png", size: Int64(4 << 20))]), "base64 counts 4/3")
        XCTAssertTrue(ChatAttachmentLimits.fitsMessage([(mime: "text/plain", size: Int64(29 << 20))]), "text goes as it is")
    }

    func testARetriedFileGetsAFreshUploadID() {
        let file = ComposerAttachment(
            id: "u1", name: "a.md", mime: "text/markdown", size: 3, file: URL(fileURLWithPath: "/dev/null"), state: .failed("x")
        )
        let retried = file.retried()
        XCTAssertNotEqual(retried.id, "u1")
        XCTAssertEqual(retried.state, .ready)
    }
}

/// The offline copy (spec §6.4, D10): kept across a relaunch, within its budget evicted by last opened, deleted
/// with the hub link; the prefetch takes the 20 most recent chats, one at a time, once per chat per hour, in the
/// foreground and while the hub answers.
@MainActor
final class ChatOfflineCopyTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func payload(_ id: Int64, text: String = "Hi") throws -> Data {
        let json: [String: Any] = [
            "conversation": ["id": id, "title": "Chat \(id)"],
            "messages": [["id": 1, "role": "assistant", "text": text, "created_at": 1_800_000_000]]
        ]
        return try JSONSerialization.data(withJSONObject: json)
    }

    func testTheCopySurvivesARelaunch() throws {
        let path = directory.appendingPathComponent(ChatOfflineCopy.fileName).path
        let classes = ProtectionClasses()
        do {
            let copy = try FileProtection.$observer.withValue({ url, type in classes.note(url, type) }, operation: {
                try ChatOfflineCopy(path: path)
            })
            try copy.saveFeed(conversationID: 3, payload: try payload(3, text: "Colleague B leads it"))
            try copy.savePage(conversationID: 3, beforeMessageID: 1, payload: Data(#"{"messages":[],"has_more":false}"#.utf8))
            try copy.markPrefetched(conversationID: 3, at: ChatFixture.now)
        }
        let reopened = try ChatOfflineCopy(path: path)
        let held = try XCTUnwrap(try reopened.held(conversationID: 3))
        XCTAssertEqual(held.feed?.messages.first?.text, "Colleague B leads it")
        XCTAssertEqual(held.pages.keys.sorted(), [1])
        XCTAssertEqual(try reopened.prefetchedAt()[3], ChatFixture.now)
        XCTAssertNil(try reopened.held(conversationID: 4), "never loaded here")
        XCTAssertEqual(classes.set[URL(fileURLWithPath: path).path], .completeUntilFirstUserAuthentication)
        if let kept = try FileProtection.protection(of: URL(fileURLWithPath: path)) {
            XCTAssertEqual(kept, .completeUntilFirstUserAuthentication, "on a device the class is kept")
        }
    }

    /// m8: a copy that does not open leaves the tab working in memory, with its line; no path (the demo) has none.
    func testACopyThatDoesNotOpenShowsItsLineAndTheTabStillWorks() throws {
        // A folder where the file should be: SQLite cannot open it.
        let blocked = directory.appendingPathComponent(ChatOfflineCopy.fileName, isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let opened = HubSession.openChatCopy(path: blocked.path)
        XCTAssertNil(opened.copy)
        XCTAssertTrue(opened.unavailable)
        let center = ChatsCenter(sender: RecordingChatSender().sender, copy: opened.copy, copyUnavailable: opened.unavailable)
        XCTAssertEqual(
            center.copyNotice,
            "Saved chats are off on this phone — chats can't be read offline and an unsent message won't survive a restart."
        )
        try center.copy.saveFeed(conversationID: 3, payload: try payload(3))
        XCTAssertNotNil(try center.copy.held(conversationID: 3), "the in-memory copy still holds what the tab shows")

        XCTAssertFalse(HubSession.openChatCopy(path: nil).unavailable)
        XCTAssertNil(ChatsCenter(sender: RecordingChatSender().sender).copyNotice)
        let fine = HubSession.openChatCopy(path: directory.appendingPathComponent("other.sqlite").path)
        XCTAssertNotNil(fine.copy)
        XCTAssertFalse(fine.unavailable)
    }

    func testOverBudgetTheLongestUnopenedChatGoesFirst() throws {
        let one = try payload(1)
        let copy = try ChatOfflineCopy(path: nil, budget: Int64(one.count * 2))
        for id: Int64 in [1, 2] { try copy.saveFeed(conversationID: id, payload: try payload(id)) }
        try copy.markOpened(conversationID: 1)
        try copy.markOpened(conversationID: 2)
        try copy.saveFeed(conversationID: 3, payload: try payload(3)) // prefetched, never opened
        try copy.saveFeed(conversationID: 4, payload: try payload(4))
        try copy.markOpened(conversationID: 4)
        try copy.evict()
        XCTAssertLessThanOrEqual(try copy.totalBytes(), Int64(one.count * 2))
        XCTAssertNil(try copy.held(conversationID: 3), "never opened goes first")
        XCTAssertNil(try copy.held(conversationID: 1), "then the oldest opened")
        XCTAssertNotNil(try copy.held(conversationID: 4))
    }

    func testTheCopyGoesWithTheHubLink() throws {
        let paths = HubPaths(groupDirectory: directory.appendingPathComponent("group"), localDirectory: directory.appendingPathComponent("local"),
                             recordingsBase: directory.appendingPathComponent("rec"))
        try paths.prepare("hub-1")
        let copy = try ChatOfflineCopy(path: paths.chatCopyPath("hub-1"))
        try copy.saveFeed(conversationID: 1, payload: try payload(1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.chatCopyPath("hub-1")))
        for folder in HubPaths.chatTempDirectories("hub-1") {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appendingPathComponent("staged"))
        }
        try paths.removeHubFiles("hub-1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.chatCopyPath("hub-1")))
        for folder in HubPaths.chatTempDirectories("hub-1") {
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "staged and sealed chat files go with the link")
        }
    }

    func testThePrefetchCadence() async throws {
        let recorder = RecordingChatSender()
        var clock = ChatFixture.now
        let copy = try ChatOfflineCopy(path: nil)
        let prefetch = ChatPrefetcher(sender: recorder.sender, copy: copy) { clock }
        let list = ChatList(conversations: (1...25).map { ChatFixture.conversation(Int64($0), ago: Double($0) * 60) })

        prefetch.step(list: list, online: false)
        prefetch.setForeground(false)
        prefetch.step(list: list, online: true)
        await Task.yield()
        XCTAssertTrue(recorder.sent.isEmpty, "offline or in the background: nothing")

        prefetch.setForeground(true)
        prefetch.step(list: list, online: true)
        prefetch.step(list: list, online: true)
        try await poll({ recorder.sent.count == 1 }, "one request")
        await Task.yield()
        let first = ChatFeedRequestParams(conversationID: 1, purpose: .prefetch)
        XCTAssertEqual(try recorder.params(ChatFeedRequestParams.self), [first], "one at a time")

        var sent: [Int64] = [1]
        for _ in 0..<30 {
            prefetch.feedsArrived([sent.last ?? 0])
            prefetch.step(list: list, online: true)
            await Task.yield()
            await Task.yield()
            sent = try recorder.params(ChatFeedRequestParams.self).map(\.conversationID)
        }
        XCTAssertEqual(sent, Array(1...20), "the 20 most recent, newest first, each once")

        clock = clock.addingTimeInterval(ChatPrefetcher.interval)
        prefetch.feedsArrived([20])
        prefetch.step(list: list, online: true)
        try await poll({ recorder.sent.count == 21 }, "an hour later")
        XCTAssertEqual(try recorder.params(ChatFeedRequestParams.self).last?.conversationID, 1)
    }
}

/// A `chat_answer` push opens its chat (spec §4.7).
@MainActor
final class NotificationRouterChatTests: XCTestCase {
    func testAChatAnswerOpensItsConversation() {
        let info: [AnyHashable: Any] = [
            WorkAlertContent.Key.hub: "hub-1", WorkAlertContent.Key.event: WorkAlertPayload.Event.chatAnswer.rawValue,
            WorkAlertContent.Key.key: "chat:t:complete", WorkAlertContent.Key.conversation: "42"
        ]
        let destination = AlertDestination.destination(userInfo: info)
        XCTAssertEqual(destination, .chat(hubID: "hub-1", conversationID: 42))
        XCTAssertEqual(destination?.hubID, "hub-1")

        let navigation = AppNavigation()
        navigation.show(.chat(hubID: "hub-1", conversationID: 42))
        XCTAssertEqual(navigation.tab, .chats)
        XCTAssertEqual(navigation.chatsPath, [ChatRoute(id: 42)])
    }

    func testAChatAnswerWithoutAConversationOpensNothing() {
        let info: [AnyHashable: Any] = [WorkAlertContent.Key.hub: "hub-1", WorkAlertContent.Key.event: "chat_answer"]
        XCTAssertNil(AlertDestination.destination(userInfo: info))
    }

    func testTheOpenChatGetsNoBanner() {
        let chat = AlertDestination.chat(hubID: "hub-1", conversationID: 42)
        XCTAssertEqual(AlertDestination.foregroundOptions(for: chat, onScreen: chat), [])
        XCTAssertEqual(AlertDestination.foregroundOptions(for: chat, onScreen: .chat(hubID: "hub-1", conversationID: 7)), [.banner, .sound])
    }
}

/// CHAT-05 on the phone: the artifact files only open or copy.
final class PhoneArtifactChat05ScanTests: XCTestCase {
    func testTheArtifactFilesSendNothing() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerMobile
        let files = [
            app.appendingPathComponent("Sources/Features/Chats/ChatArtifactSheet.swift"),
            app.appendingPathComponent("Sources/Features/Chats/SandboxedArtifactWebView.swift"),
            // The artifact links the reply resolves (shared with the Mac).
            app.deletingLastPathComponent()
                .appendingPathComponent("WatchtowerChatText/Sources/WatchtowerChatText/ArtifactLinks.swift")
        ]
        for file in files {
            let name = file.lastPathComponent
            let source = try String(contentsOf: file, encoding: .utf8)
            for banned in ["URLSession", "enqueue", "send(", "ActionOutbox", "ChatSender", "addScriptMessageHandler"] {
                XCTAssertFalse(source.contains(banned), "\(name) must not use \(banned)")
            }
        }
    }

    func testTheHTMLPolicyBlocksEveryRemoteLoad() throws {
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ArtifactHTMLPolicy.contentRules.utf8)) as? [[String: Any]])
        let first = try XCTUnwrap(rules.first)
        XCTAssertEqual((first["action"] as? [String: String])?["type"], "block")
        XCTAssertEqual((first["trigger"] as? [String: String])?["url-filter"], ".*")
        let allowed = rules.dropFirst().compactMap { ($0["trigger"] as? [String: String])?["url-filter"] }
        XCTAssertEqual(allowed, ["^about:", "^data:", "^blob:"])
        XCTAssertTrue(ArtifactHTMLPolicy.allowsNavigation(to: URL(string: "about:blank")))
        XCTAssertFalse(ArtifactHTMLPolicy.allowsNavigation(to: URL(string: "https://example.com")))
        XCTAssertFalse(ArtifactHTMLPolicy.allowsNavigation(to: URL(string: "file:///etc/hosts")))
        XCTAssertFalse(ArtifactHTMLPolicy.allowsNavigation(to: nil))
    }
}

/// The artifact sheet's buttons (spec §6.2, mockup 3b).
final class ChatArtifactActionsTests: XCTestCase {
    private func artifact(_ kind: String, meta: [String: String] = [:], content: String = "Body") -> ChatArtifactContent {
        ChatArtifactContent(key: "k", kind: kind, title: "Design review", version: 2, meta: meta, content: content, contentCut: false)
    }

    private func query(_ url: URL) -> [String: String] {
        Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { $1 }
    }

    func testEmailOpensAMailtoWithEverythingEncoded() throws {
        let meta = ["to": "vendor@example.com", "subject": "Re: renewal & terms"]
        let actions = ChatArtifactActions(artifact("email", meta: meta, content: "Hello, a+b"))
        XCTAssertEqual(actions.buttons.map(\.title), ["Open in Mail", "Copy", "Share"])
        guard case let .open(url) = actions.buttons[0].effect else { return XCTFail("open") }
        XCTAssertTrue(url.absoluteString.hasPrefix("mailto:vendor%40example.com?"))
        XCTAssertEqual(query(url)["subject"], "Re: renewal & terms")
        XCTAssertEqual(query(url)["body"], "Hello, a+b")
        XCTAssertEqual(actions.buttons[1].effect, .copy("To: vendor@example.com\nSubject: Re: renewal & terms\n\nHello, a+b"))
    }

    func testEventOpensTheGoogleCalendarTemplate() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let actions = ChatArtifactActions(artifact("event", meta: ["start": "2026-09-30T10:00:00+03:00", "location": "Room 4"], content: "Agenda"),
                                          timeZone: utc)
        guard case let .open(url) = actions.buttons[0].effect else { return XCTFail("open") }
        XCTAssertTrue(url.absoluteString.hasPrefix("https://calendar.google.com/calendar/render?action=TEMPLATE&"))
        XCTAssertEqual(query(url)["text"], "Design review")
        XCTAssertEqual(query(url)["dates"], "20260930T070000Z/20260930T080000Z")
        XCTAssertEqual(query(url)["details"], "Agenda")
    }

    func testSlackCopiesTheTextAndOpensTheSlackApp() {
        let actions = ChatArtifactActions(artifact("slack", meta: ["channel": "#release"], content: "Release 1.4 is out"))
        XCTAssertEqual(actions.buttons[0].effect, .copyThenOpen(text: "Release 1.4 is out", url: URL(string: "slack://open")))
        let permalink = ChatArtifactActions(artifact("slack", meta: ["permalink": "https://acme.slack.com/archives/C1/p1"], content: "x"))
        XCTAssertEqual(permalink.buttons[0].effect, .copyThenOpen(text: "x", url: URL(string: "https://acme.slack.com/archives/C1/p1")))
    }

    func testCopyAndShareOnEveryKind() {
        for kind in ["document", "table", "code", "html", "email", "event", "slack"] {
            let titles = ChatArtifactActions(artifact(kind)).buttons.map(\.title)
            XCTAssertEqual(Array(titles.suffix(2)), ["Copy", "Share"], kind)
        }
        XCTAssertEqual(ChatArtifactActions(artifact("document")).buttons.count, 2, "a document only copies and shares")
        XCTAssertEqual(ChatArtifactActions.markdown(artifact("code", meta: ["language": "go"], content: "x := 1")), "```go\nx := 1\n```")
    }
}

/// The protection classes a test's code set (the simulator keeps none).
private final class ProtectionClasses: @unchecked Sendable {
    private let lock = NSLock()
    private var classes: [String: FileProtectionType] = [:]

    var set: [String: FileProtectionType] { lock.withLock { classes } }

    func note(_ url: URL, _ type: FileProtectionType) {
        lock.withLock { classes[url.path] = type }
    }
}

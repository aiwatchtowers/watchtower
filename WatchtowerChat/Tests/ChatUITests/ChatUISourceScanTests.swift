import ChatWire
import XCTest
import WatchtowerChatText
@testable import ChatUI

/// Source scans of the ChatUI target: its imports, and CHAT-05 over its artifact, fallback and link surfaces.
final class ChatUISourceScanTests: XCTestCase {
    private func swiftFiles(under root: URL) throws -> [URL] {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "swift" { files.append(url) }
        }
        return files
    }

    private func relative(_ url: URL) -> String {
        String(url.path.dropFirst(ChatUIFixtures.chatUISources.path.count + 1))
    }

    /// ChatUI builds on ChatWire, WatchtowerChatText and the Kit's design tokens only: never Core, GRDB, the Kit's
    /// models or the Desktop's DesignKit (spec §6.1, §14). AppKit and UIKit appear only in the platform parts.
    func testChatUIImportsOnlyAllowedModules() throws {
        let common: Set = ["Foundation", "SwiftUI", "Observation", "ChatWire", "WatchtowerChatText", "WatchtowerDesign"]
        let mac: Set = ["AppKit", "WebKit", "UniformTypeIdentifiers", "os"]
        let phone: Set = ["UIKit", "WebKit", "UniformTypeIdentifiers", "os", "PhotosUI"]
        let files = try swiftFiles(under: ChatUIFixtures.chatUISources)
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let path = relative(file)
            let allowed = path.hasPrefix("Platform/macOS/") ? common.union(mac)
                : path.hasPrefix("Platform/iOS/") ? common.union(phone) : common
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") where line.hasPrefix("import ") || line.hasPrefix("@testable import ") {
                let module = String(line.split(separator: " ").last ?? "")
                XCTAssertTrue(allowed.contains(module), "\(path) imports \(module)")
            }
            if path.hasPrefix("Platform/") {
                let guardLine = path.hasPrefix("Platform/macOS/") ? "#if os(macOS)" : "#if os(iOS)"
                XCTAssertTrue(text.contains(guardLine), "\(path) sits behind \(guardLine) (D9)")
            }
        }
    }

    private static let forbidden = [
        "Process(", "CLIRunner", "URLSession", "findCLIPath", "WatchtowerAIService", "ChatSessionPool",
        ".send(", "sendDraft", "startTurn", "client.", "ChatClient",
        "LocalPreviewServer", "HTMLBrowserOpener", "NWConnection", "NWListener",
    ]

    /// BEHAVIOR CHAT-05 — see docs/inventory/chat.md
    /// The fallback, artifact and published-link surfaces only open or copy (or post a fixed owner text the owner
    /// pressed, through the screen): none reaches the client, a process or the network.
    func testChat05FallbackAndArtifactActionsOnlyOpenOrCopy() throws {
        let files = [
            "Parts/FallbackPartView.swift",
            "Parts/ArtifactPartView.swift",
            "Parts/PublishedLinkPartView.swift",
            "Artifacts/ArtifactViewer.swift",
            "Platform/macOS/ArtifactPrinter.swift",
            "Platform/macOS/SandboxedHTMLGlue.swift",
            "Platform/macOS/PresentWindow.swift",
            "Platform/iOS/SandboxedArtifactWebView.swift",
        ]
        for file in files {
            let text = try String(contentsOf: ChatUIFixtures.chatUISources.appendingPathComponent(file), encoding: .utf8)
            for token in Self.forbidden {
                XCTAssertFalse(text.contains(token), "\(file) must not reference \(token) (CHAT-05)")
            }
        }
        let shapes: [(ChatPartFallback.Action, FallbackPartView.Effect)] = [
            (.init(label: "x", action: "open_url", url: "javascript:alert(1)"), .none),
            (.init(label: "x", action: "open_url", url: "file:///etc/hosts"), .none),
            (.init(label: "x", action: "open_url", url: "smb://host/share"), .none),
            (.init(label: "x", action: "chat_turn", text: "  "), .none),
            (.init(label: "x", action: "write_db", text: "drop"), .none),
            (.init(label: "x", action: "chat_turn", text: "Go on"), .turn("Go on")),
        ]
        for (action, effect) in shapes {
            XCTAssertEqual(FallbackPartView.effect(action), effect, "\(action)")
        }
    }

    func testPasteClassifierTextLimitMatchesAttachmentLimits() {
        XCTAssertEqual(PasteClassifier.textAttachmentLimit, ChatAttachmentLimits.textLimit)
    }
}

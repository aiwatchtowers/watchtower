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
        "LocalPreviewServer", "HTMLBrowserOpener", "NWConnection", "NWListener"
    ]

    /// BEHAVIOR CHAT-05 — see docs/inventory/chat.md
    /// The fallback, artifact and published-link surfaces only open or copy (or post a fixed owner text the owner
    /// pressed, through the screen): none reaches the client, a process or the network.
    func testChat05FallbackAndArtifactActionsOnlyOpenOrCopy() throws {
        let files = [
            "Parts/FallbackPartView.swift",
            "Parts/ArtifactPartView.swift",
            "Parts/PublishedLinkPartView.swift",
            // The row every chat draws (main, embedded, Workchat, phone) and the question card that posts the owner's
            // picked answers through the screen (unified chat T12).
            "Feed/ChatMessageRow.swift",
            "Parts/QuestionPartView.swift",
            "Artifacts/ArtifactViewer.swift",
            // The phone's artifact viewer controls and the sources list (final review M2).
            "Platform/iOS/ArtifactViewerParts.swift",
            "Parts/SourcesPartView.swift",
            "Platform/macOS/ArtifactPrinter.swift",
            "Platform/macOS/SandboxedHTMLGlue.swift",
            "Platform/macOS/PresentWindow.swift",
            "Platform/iOS/SandboxedArtifactWebView.swift",
            // The approval card both devices draw (unified chat T15): its effects go through the injected services.
            "Parts/ApprovalPartView.swift",
            "Parts/Approval/AgentActionCard.swift",
            "Parts/Approval/AgentActionCard+Decision.swift",
            "Parts/Approval/AgentActionCard+Slack.swift",
            "Parts/Approval/AgentActionCard+Confluence.swift",
            "Parts/Approval/AgentActionCard+Connector.swift",
            "Parts/Approval/ApprovalServices.swift",
            "Parts/Approval/ApproveAllRow.swift",
            "Platform/macOS/ConnectorInputEditor+Mac.swift",
            "Platform/iOS/ConnectorInputEditor+Phone.swift"
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
            (.init(label: "x", action: "chat_turn", text: "Go on"), .turn("Go on"))
        ]
        for (action, effect) in shapes {
            XCTAssertEqual(FallbackPartView.effect(action), effect, "\(action)")
        }
    }

    /// BEHAVIOR CHAT-05 — see docs/inventory/chat.md
    /// The composer's views (every file under Composer/, enumerated, and the platform text inputs and file input) only
    /// edit their binding and call their closures: none reaches the client, a process or the network. The main
    /// composer view alone drives its model's `send()` (the engine's echo decides, CHAT-01), so `.send(` is allowed
    /// there and nowhere else.
    func testChat05ComposerOnlyEditsItsBindingAndCallsClosures() throws {
        let composer = try swiftFiles(under: ChatUIFixtures.chatUISources.appendingPathComponent("Composer")).map(relative)
        XCTAssertTrue(composer.contains("Composer/ChatComposerField.swift"))
        let files = composer + [
            "Platform/macOS/ChatComposerTextInput.swift",
            "Platform/macOS/ComposerFileInput.swift",
            "Platform/macOS/LongPasteOffer.swift",
            "Platform/iOS/ComposerTextField.swift",
            "Platform/iOS/PhoneComposerFileInput.swift"
        ]
        for file in files {
            let text = try String(contentsOf: ChatUIFixtures.chatUISources.appendingPathComponent(file), encoding: .utf8)
            let tokens = file == "Composer/ChatComposerView.swift" ? Self.forbidden.filter { $0 != ".send(" } : Self.forbidden
            for token in tokens {
                XCTAssertFalse(text.contains(token), "\(file) must not reference \(token) (CHAT-05)")
            }
        }
    }

    func testPasteClassifierTextLimitMatchesAttachmentLimits() {
        XCTAssertEqual(PasteClassifier.textAttachmentLimit, ChatAttachmentLimits.textLimit)
    }
}

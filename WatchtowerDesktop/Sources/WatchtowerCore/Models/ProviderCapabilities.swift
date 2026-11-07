import Foundation

/// What a provider's transport offers: the Go capability table
/// (`internal/providers/caps`, spec 2026-11-05 §3.3), read only from
/// `watchtower ai models --json` (`AIModelCatalog`) and a chat's
/// `session_ready`. Swift decides nothing the table does not say
/// (LLMTRANSPORT-01): no provider name picks a behaviour here. The keys are
/// pinned by the Go-written `Tests/Core/Fixtures/ai_models_capabilities.json`.
package struct ProviderCapabilities: Decodable, Equatable, Sendable {
    /// none | watchtower | watchtower+quick_connections.
    package let tools: String
    package let toolEvents: Bool
    /// token | message | final.
    package let textStream: String
    /// none | totals | split.
    package let usage: String
    package let costReported: Bool
    package let images: Bool
    package let pdfs: Bool
    package let webSearch: Bool
    /// none | tools | shell_sandbox.
    package let readFolder: String
    /// native | counted | none.
    package let turnCap: String
    /// in_turn | kill_turn.
    package let interrupt: String
    package let warmSession: Bool
    package let claudeAITools: Bool
    /// The provider a fallback pairs this one with; "" = none.
    package let reservePeer: String
    package let quota: Bool

    enum CodingKeys: String, CodingKey {
        case tools
        case toolEvents = "tool_events"
        case textStream = "text_stream"
        case usage
        case costReported = "cost_reported"
        case images, pdfs
        case webSearch = "web_search"
        case readFolder = "read_folder"
        case turnCap = "turn_cap"
        case interrupt
        case warmSession = "warm_session"
        case claudeAITools = "claude_ai_tools"
        case reservePeer = "reserve_peer"
        case quota
    }

    package init(
        tools: String = "none",
        toolEvents: Bool = false,
        textStream: String = "final",
        usage: String = "none",
        costReported: Bool = false,
        images: Bool = false,
        pdfs: Bool = false,
        webSearch: Bool = false,
        readFolder: String = "none",
        turnCap: String = "none",
        interrupt: String = "kill_turn",
        warmSession: Bool = false,
        claudeAITools: Bool = false,
        reservePeer: String = "",
        quota: Bool = false
    ) {
        self.tools = tools; self.toolEvents = toolEvents; self.textStream = textStream; self.usage = usage
        self.costReported = costReported; self.images = images; self.pdfs = pdfs; self.webSearch = webSearch
        self.readFolder = readFolder; self.turnCap = turnCap; self.interrupt = interrupt
        self.warmSession = warmSession; self.claudeAITools = claudeAITools; self.reservePeer = reservePeer
        self.quota = quota
    }

    /// A row that offers nothing: what an unknown provider, or a catalog not
    /// read yet, takes — the honest default.
    package static let none = Self()

    /// The transport runs the watchtower tools.
    package var hasTools: Bool { !tools.isEmpty && tools != "none" }
    /// The owner's Quick Connections reach the transport.
    package var takesQuickConnections: Bool { tools == "watchtower+quick_connections" }
    /// The transport reads a folder's files itself.
    package var readsFolder: Bool { !readFolder.isEmpty && readFolder != "none" }
    /// The transport takes any binary attachment (an image or a PDF).
    package var takesAttachments: Bool { images || pdfs }

    /// Why the composer cannot attach a file to this transport (mockup U1,
    /// spec §3.7); nil when it takes images or PDFs.
    package var attachUnavailableReason: String? {
        takesAttachments ? nil : "Images and PDFs need a provider that reads them."
    }

    /// Why the composer refuses a PDF from a transport that takes images
    /// only (Codex); nil when it takes PDFs, or takes no attachment at all
    /// (`attachUnavailableReason` names that).
    package var pdfUnavailableReason: String? {
        takesAttachments && !pdfs ? "PDFs need a provider that reads them." : nil
    }
}

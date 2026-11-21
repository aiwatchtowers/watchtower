import ChatWire
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
    /// browser | words | none: how the provider's agent can guide a
    /// connection (agent connect); "none" when the row has no key (an older
    /// CLI, or a chat's `session_ready`).
    package let connect: String

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
        case connect
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
        quota: Bool = false,
        connect: String = ConnectCapability.none.rawValue
    ) {
        self.tools = tools; self.toolEvents = toolEvents; self.textStream = textStream; self.usage = usage
        self.costReported = costReported; self.images = images; self.pdfs = pdfs; self.webSearch = webSearch
        self.readFolder = readFolder; self.turnCap = turnCap; self.interrupt = interrupt
        self.warmSession = warmSession; self.claudeAITools = claudeAITools; self.reservePeer = reservePeer
        self.quota = quota; self.connect = connect
    }

    /// Every key is required but `connect`, which a row from an older CLI
    /// or a chat's `session_ready` may not carry.
    package init(from decoder: any Decoder) throws {
        let row = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            tools: row.decode(String.self, forKey: .tools),
            toolEvents: row.decode(Bool.self, forKey: .toolEvents),
            textStream: row.decode(String.self, forKey: .textStream),
            usage: row.decode(String.self, forKey: .usage),
            costReported: row.decode(Bool.self, forKey: .costReported),
            images: row.decode(Bool.self, forKey: .images),
            pdfs: row.decode(Bool.self, forKey: .pdfs),
            webSearch: row.decode(Bool.self, forKey: .webSearch),
            readFolder: row.decode(String.self, forKey: .readFolder),
            turnCap: row.decode(String.self, forKey: .turnCap),
            interrupt: row.decode(String.self, forKey: .interrupt),
            warmSession: row.decode(Bool.self, forKey: .warmSession),
            claudeAITools: row.decode(Bool.self, forKey: .claudeAITools),
            reservePeer: row.decode(String.self, forKey: .reservePeer),
            quota: row.decode(Bool.self, forKey: .quota),
            connect: row.decodeIfPresent(String.self, forKey: .connect) ?? ConnectCapability.none.rawValue
        )
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
    /// How the connect assistant can run on this provider; a value this
    /// build does not know offers no assistant.
    package var connectMode: ConnectCapability { ConnectCapability(rawValue: connect) ?? ConnectCapability.none }
    /// The transport takes any binary attachment (an image or a PDF).
    package var takesAttachments: Bool { chatCaps.takesAttachments }

    /// Why the composer cannot attach a file to this transport (mockup U1,
    /// spec §3.7); nil when it takes images or PDFs. The copy is the chat's
    /// (`ChatProviderCaps`), one table for the Mac and the phone.
    package var attachUnavailableReason: String? { chatCaps.attachUnavailableReason }

    /// Why the composer refuses a PDF from a transport that takes images
    /// only (Codex); nil when it takes PDFs, or takes no attachment at all
    /// (`attachUnavailableReason` names that).
    package var pdfUnavailableReason: String? { chatCaps.pdfUnavailableReason }
}

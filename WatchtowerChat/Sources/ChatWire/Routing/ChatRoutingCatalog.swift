import Foundation

/// What a provider's transport offers that the routing pill, the composer and the fallback card read: a subset of the
/// Go capability table's row (`internal/providers/caps`). Swift decides by these rows, never by a provider's name
/// (LLMTRANSPORT-01).
public struct ChatProviderCaps: Equatable, Hashable, Sendable {
    public var images: Bool
    public var pdfs: Bool
    public var readFolder: Bool
    public var claudeAITools: Bool

    public init(images: Bool = false, pdfs: Bool = false, readFolder: Bool = false, claudeAITools: Bool = false) {
        self.images = images
        self.pdfs = pdfs
        self.readFolder = readFolder
        self.claudeAITools = claudeAITools
    }

    /// The transport takes any binary attachment (an image or a PDF).
    public var takesAttachments: Bool { images || pdfs }

    /// Why the composer cannot attach a file to this transport (mockup U1, spec §3.7); nil when it takes images or
    /// PDFs.
    public var attachUnavailableReason: String? {
        takesAttachments ? nil : "Images and PDFs need a provider that reads them."
    }

    /// Why the composer refuses a PDF from a transport that takes images only; nil when it takes PDFs, or takes no
    /// attachment at all (`attachUnavailableReason` names that).
    public var pdfUnavailableReason: String? {
        takesAttachments && !pdfs ? "PDFs need a provider that reads them." : nil
    }
}

/// The providers a chat's routing pill offers, with their models, fallback peers and capability rows, and the routing
/// status the fallback card reads. The Mac builds it from `ai models` and `ai routing-status`; the phone from the
/// `chat_list` record's `models[]` and optional `routing` (an older daemon sends no `routing`: models only, D22).
public struct ChatRoutingCatalog: Equatable, Sendable {
    public struct Provider: Equatable, Sendable {
        public let id: String
        public let displayName: String
        /// The provider a fallback pairs this one with (the table's `reserve_peer`); nil: none.
        public let reservePeer: String?
        public let models: [String]
        public let caps: ChatProviderCaps

        public init(
            id: String,
            displayName: String,
            reservePeer: String? = nil,
            models: [String] = [],
            caps: ChatProviderCaps = ChatProviderCaps()
        ) {
            self.id = id
            self.displayName = displayName
            self.reservePeer = reservePeer.flatMap { $0.isEmpty ? nil : $0 }
            self.models = models
            self.caps = caps
        }
    }

    public var providers: [Provider]
    /// The routing status (preferred provider, fallback on, availability); nil: no preview card.
    public var status: ChatRoutingStatus?
    /// Why the status could not be read, as a line under the pill.
    public var statusError: String?
    /// Whether the rows' capabilities are the transport table's (false: an older daemon's `models[]` alone, or the
    /// Mac before `ai models` was read — no capability line is drawn from them).
    public var capabilitiesKnown: Bool

    public init(providers: [Provider], status: ChatRoutingStatus?, statusError: String?, capabilitiesKnown: Bool = true) {
        self.providers = providers
        self.status = status
        self.statusError = statusError
        self.capabilitiesKnown = capabilitiesKnown
    }

    /// The phone's catalog: the record's `models[]`, grouped by provider in their order, and its `routing` when the
    /// daemon sends one (the providers, their pair and capability rows, the status). Without `routing` the providers
    /// come from `models[]` alone: no pair, and only the images/PDF capabilities.
    public init(list: ChatList) {
        var order: [String] = []
        var models: [String: [String]] = [:]
        var names: [String: String] = [:]
        var caps: [String: ChatProviderCaps] = [:]
        for model in list.models {
            if models[model.provider] == nil {
                order.append(model.provider)
                models[model.provider] = []
                names[model.provider] = model.displayName
                caps[model.provider] = ChatProviderCaps()
            }
            if !model.model.isEmpty, models[model.provider]?.contains(model.model) == false {
                models[model.provider]?.append(model.model)
            }
            var row = caps[model.provider] ?? ChatProviderCaps()
            row.images = row.images || model.images
            row.pdfs = row.pdfs || model.pdf
            caps[model.provider] = row
        }
        guard let routing = list.routing else {
            self.init(providers: order.map { id in
                Provider(id: id, displayName: names[id] ?? id, models: models[id] ?? [], caps: caps[id] ?? ChatProviderCaps())
            }, status: nil, statusError: nil, capabilitiesKnown: false)
            return
        }
        self.init(providers: routing.providers.map { row in
            Provider(id: row.id, displayName: row.displayName, reservePeer: row.reservePeer, models: models[row.id] ?? [],
                     caps: ChatProviderCaps(images: row.images, pdfs: row.pdfs, readFolder: row.readFolder,
                                            claudeAITools: row.claudeAITools))
        }, status: routing.status, statusError: routing.error)
    }

    public func provider(_ id: String) -> Provider? { providers.first { $0.id == id } }

    /// The fallback pair `preferred` heads: its reserve peer, when that peer is listed and pairs back.
    public func pair(preferred: String) -> ProviderFallbackPreview.Pair? {
        guard let head = provider(preferred), let peerID = head.reservePeer, let peer = provider(peerID),
              peer.reservePeer == head.id else { return nil }
        return ProviderFallbackPreview.Pair(preferred: .init(id: head.id, name: head.displayName),
                                            reserve: .init(id: peer.id, name: peer.displayName))
    }
}

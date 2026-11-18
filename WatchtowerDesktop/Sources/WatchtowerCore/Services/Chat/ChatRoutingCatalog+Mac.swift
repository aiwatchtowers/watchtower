import ChatWire
import Foundation

extension ChatRoutingCatalog {
    /// The Mac's catalog: the providers the chat offers (`AIProvider.offered`, in the catalog's order) with their
    /// display names, fallback peers, model suggestions and capability rows from `ai models` (`AIModelCatalog`), and
    /// the `ai routing-status` read. Before `ai models` is read the providers are the offered ones with no models and
    /// no capability line, as before.
    @MainActor
    package init(models: AIModelCatalog, offered: [String], status: ChatRoutingStatus?, statusError: String?) {
        self.init(providers: offered.map { id in
            Provider(id: id, displayName: models.displayName(id), reservePeer: models.reservePeer(of: id),
                     models: models.suggestions(for: id), caps: models.capabilities(for: id).chatCaps)
        }, status: status, statusError: statusError, capabilitiesKnown: models.isLoaded)
    }
}

extension ProviderCapabilities {
    /// The part of the row the chat's routing pill, composer and fallback card read.
    package var chatCaps: ChatProviderCaps {
        ChatProviderCaps(images: images, pdfs: pdfs, readFolder: readsFolder, claudeAITools: claudeAITools)
    }
}

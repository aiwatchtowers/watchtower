import ChatWire
import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The Mac's routing catalog (#1822 T17): `ai models` gives the pair, the models and the capability rows; before it is
/// read the providers are the offered ones with Auto only and no capability line.
@MainActor
final class ChatRoutingMacAdapterTests: XCTestCase {
    func testMacCatalogMapsPairCapsAndSuggestions() throws {
        let models = AIModelCatalog(providers: ProviderCatalogFixture.providers())
        let status = try ChatRoutingStatus.parse(Data("""
            {"preferred_provider":"claude","enabled":true,"revision":"r","providers":[{"provider":"claude","state":"quota_wait"}]}
            """.utf8))
        let catalog = ChatRoutingCatalog(models: models, offered: models.providerIDs, status: status, statusError: nil)
        XCTAssertEqual(catalog.providers.map(\.id), models.providerIDs)
        for id in models.providerIDs {
            XCTAssertEqual(catalog.pair(preferred: id), models.fallbackPair(preferred: id), id)
            XCTAssertEqual(catalog.provider(id)?.models, models.suggestions(for: id), id)
            let row = models.capabilities(for: id)
            let caps = ChatProviderCaps(images: row.images, pdfs: row.pdfs, readFolder: row.readsFolder,
                                        claudeAITools: row.claudeAITools)
            XCTAssertEqual(catalog.provider(id)?.caps, caps, id)
            XCTAssertEqual(catalog.provider(id)?.displayName, models.displayName(id))
        }
        XCTAssertEqual(catalog.status, status)
        XCTAssertTrue(catalog.capabilitiesKnown)
    }

    func testUnreadCatalogOffersProvidersAndAutoOnly() {
        let unread = AIModelCatalog(providers: [])
        let catalog = ChatRoutingCatalog(models: unread, offered: ["claude"], status: nil, statusError: nil)
        XCTAssertEqual(catalog.providers.map(\.id), ["claude"])
        XCTAssertEqual(catalog.providers.first?.models, [])
        XCTAssertNil(catalog.pair(preferred: "claude"))
        XCTAssertFalse(catalog.capabilitiesKnown, "no capability line before `ai models` is read")
    }
}

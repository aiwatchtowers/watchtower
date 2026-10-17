import Foundation

/// The user guide index produced by `watchtower guide index --json`.
package struct GuideIndex: Decodable, Sendable {
    package let version: String
    package let baseURL: String
    package let catalog: String
    package let sections: [GuideSection]

    private enum CodingKeys: String, CodingKey {
        case version, catalog, sections
        case baseURL = "base_url"
    }
}

package struct GuideSection: Decodable, Sendable, Identifiable {
    package let page: String
    package let pageTitle: String
    package let heading: String
    package let anchor: String
    package let level: Int
    package let text: String

    package var id: String { page + "#" + anchor }

    private enum CodingKeys: String, CodingKey {
        case page, heading, anchor, level, text
        case pageTitle = "page_title"
    }

    package init(page: String, pageTitle: String, heading: String, anchor: String, level: Int, text: String) {
        self.page = page
        self.pageTitle = pageTitle
        self.heading = heading
        self.anchor = anchor
        self.level = level
        self.text = text
    }

    /// The section's page on the guide site: `base_url + page + "#" + anchor`.
    package func url(in index: GuideIndex) -> URL? {
        URL(string: index.baseURL + page + "#" + anchor)
    }
}

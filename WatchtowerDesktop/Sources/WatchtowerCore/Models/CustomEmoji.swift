import GRDB

package struct CustomEmoji: FetchableRecord, Decodable, Identifiable {
    package let name: String
    package let url: String
    package let aliasFor: String

    package var id: String { name }

    /// True if this emoji is an alias for another custom emoji.
    package var isAlias: Bool { !aliasFor.isEmpty }

    package enum CodingKeys: String, CodingKey {
        case name, url
        case aliasFor = "alias_for"
    }
}

import Foundation

/// A key of the live feed's snake_case wire JSON (Go `sessionfeed.Live`,
/// read from the CLI's `--json` on the Mac and from the hub's
/// `activity_live` on the phone). The phone's `RelayCoder` decodes with
/// `.convertFromSnakeCase`, which hands `observed_at` over as `observedAt`,
/// so a multi-word key is looked up in both spellings.
struct FeedWireKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }

    /// `tool_use_id` -> `toolUseId`, the way `.convertFromSnakeCase` spells it.
    static func camel(_ snake: String) -> String {
        let parts = snake.split(separator: "_")
        guard let head = parts.first, parts.count > 1 else { return snake }
        return String(head) + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }
}

extension KeyedDecodingContainer where K == FeedWireKey {
    /// The value under `snake`, or under its camelCase spelling; nil when
    /// neither is present.
    func wire<T: Decodable>(_ type: T.Type, _ snake: String) throws -> T? {
        if let value = try decodeIfPresent(type, forKey: FeedWireKey(snake)) { return value }
        let camel = FeedWireKey.camel(snake)
        guard camel != snake else { return nil }
        return try decodeIfPresent(type, forKey: FeedWireKey(camel))
    }

    func wireDate(_ snake: String) throws -> Date? {
        SessionFeedDate.parse(try wire(String.self, snake))
    }
}

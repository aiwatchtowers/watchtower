import Foundation

/// One line of `watchtower workbench cleanup --json --stream`
/// (spec 2026-10-26-worktree-cleanup-screen §6). A line that is not JSON or
/// names an event this build does not know decodes to nil: garbage on stdout
/// is skipped, never fatal.
package enum SessionCleanupEvent: Equatable, Sendable {
    case listed([SessionCleanupItem])
    case checked(SessionCleanupItem)
    case sized(key: String, bytes: Int64, known: Bool)
    case removing(String)
    case removed(SessionCleanupItem)
    case done(SessionCleanupPlan)

    private struct Line: Decodable {
        var event: String
        var items: [SessionCleanupItem]?
        var item: SessionCleanupItem?
        var key: String?
        var bytes: Int64?
        // Synthesised decoding needs an optional for an absent key.
        // swiftlint:disable:next discouraged_optional_boolean
        var bytesKnown: Bool?
        var plan: SessionCleanupPlan?

        enum CodingKeys: String, CodingKey {
            case event, items, item, key, bytes, plan
            case bytesKnown = "bytes_known"
        }
    }

    package static func decode(line: String) -> Self? {
        guard let parsed = try? JSONDecoder().decode(Line.self, from: Data(line.utf8)) else { return nil }
        switch parsed.event {
        case "listed": return parsed.items.map(Self.listed)
        case "checked": return parsed.item.map(Self.checked)
        case "sized":
            guard let key = parsed.key else { return nil }
            return .sized(key: key, bytes: parsed.bytes ?? 0, known: parsed.bytesKnown ?? false)
        case "removing": return parsed.key.map(Self.removing)
        case "removed": return parsed.item.map(Self.removed)
        case "done": return parsed.plan.map(Self.done)
        default: return nil
        }
    }
}

/// Where a streamed plan stands; the center publishes it and the screen
/// model words it.
package enum CleanupStage: Equatable, Sendable {
    case listing
    case checking(done: Int, of: Int)
    case sizing(done: Int, of: Int)
    case ready(at: Date)
    case applying
    case done(SessionCleanupPlan)
    case failed(String)
}

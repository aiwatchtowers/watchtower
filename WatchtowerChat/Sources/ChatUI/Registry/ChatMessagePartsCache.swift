import ChatWire
import Foundation

/// The parts the feed last derived for each message (final review I4): a message whose content did not change keeps
/// its parts, so a streaming `message_upsert` re-derives only the message it changed instead of decoding every loaded
/// message's payloads and running the question and artifact parsers over all of them on each body pass. Keyed by the
/// message id; the stored message is the content revision (any changed text, status, part or step is a new one). It
/// keeps only the messages of the last pass. A view holds one in `@State`; it is never observed, so a lookup does not
/// redraw anything.
public final class ChatMessagePartsCache {
    private struct Entry {
        let message: ChatFeed.Message
        let parts: [ChatPart]
    }

    private var entries: [Int64: Entry] = [:]
    /// How many messages the last passes derived (tests).
    private(set) var derivedCount = 0

    public init() {}

    /// Each message's parts, in order; a message equal to the one cached under its id reuses its parts.
    func parts(for messages: [ChatFeed.Message]) -> [[ChatPart]] {
        var next: [Int64: Entry] = [:]
        next.reserveCapacity(messages.count)
        let out = messages.map { message -> [ChatPart] in
            if let entry = entries[message.id], entry.message == message {
                next[message.id] = entry
                return entry.parts
            }
            derivedCount += 1
            let parts = ChatMessageParts.parts(for: message)
            next[message.id] = Entry(message: message, parts: parts)
            return parts
        }
        entries = next
        return out
    }
}

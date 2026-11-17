import Foundation

package struct ChatCommandAttachment: Codable, Equatable, Sendable {
    package let path: String
    package let mime: String
    package let name: String

    package init(path: String, mime: String, name: String) {
        self.path = path
        self.mime = mime
        self.name = name
    }
}

package struct ChatTurnCommand: Equatable, Sendable {
    package let turnID: String
    package let text: String
    package let attachments: [ChatCommandAttachment]
    /// The provider session is not continuous with this branch — Go rebuilds
    /// the history from `chat_messages` (spec §2.4). Under `--persist` Go
    /// decides it (a regenerate or an edit always replays).
    package let replay: Bool
    /// `--persist`: what the turn's starting rows are (mobile Inbox spec §8);
    /// the session writes them before the provider gets the turn.
    package let start: ChatTurnStart?

    package init(
        turnID: String,
        text: String,
        attachments: [ChatCommandAttachment],
        replay: Bool,
        start: ChatTurnStart? = nil
    ) {
        self.turnID = turnID
        self.text = text
        self.attachments = attachments
        self.replay = replay
        self.start = start
    }
}

/// A persisted turn's starting rows, as the session's `turn` line carries
/// them (`internal/chat.Command`): `ai session --persist` runs
/// `chatstore.Start` on them.
package struct ChatTurnStart: Equatable, Sendable {
    package enum Mode: String, Sendable {
        case send, regenerate, edit
    }

    package let mode: Mode
    /// A send: the conversation's pending files to link to the owner row.
    package let attachmentIDs: [Int64]
    /// A regenerate: the owner message answered again.
    package let parentID: Int64?
    /// An edit: the owner message replaced (its new text is the turn's text).
    package let editMessageID: Int64?
    /// A send: the artifact comments of a "Send N comments" batch, marked
    /// sent in the owner row's transaction.
    package let quotes: [Int64]
    /// A send: the owner's own words (the prefix title's source); the turn's
    /// text is then stored as given (skill line, mentions).
    package let titleText: String?
    /// A send: the help popup's current-screen block, sent ahead of the
    /// text and never stored.
    package let screen: String?

    package init(
        mode: Mode,
        attachmentIDs: [Int64] = [],
        parentID: Int64? = nil,
        editMessageID: Int64? = nil,
        quotes: [Int64] = [],
        titleText: String? = nil,
        screen: String? = nil
    ) {
        self.mode = mode
        self.attachmentIDs = attachmentIDs
        self.parentID = parentID
        self.editMessageID = editMessageID
        self.quotes = quotes
        self.titleText = titleText
        self.screen = screen
    }
}

/// One JSONL command on the session's stdin. Text and attachment paths
/// travel ONLY here, never on argv (CHAT-04).
package enum ChatCommand: Equatable, Sendable {
    case turn(ChatTurnCommand)
    case cancel
    case close

    package func jsonLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Wire(command: self))
        guard let line = String(bytes: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "non-UTF-8 JSON"))
        }
        return line
    }

    /// `cancel`/`close` carry only `type`; a turn carries every field, with
    /// `attachments` always an array (never `null`).
    private struct Wire: Encodable {
        let command: ChatCommand

        enum CodingKeys: String, CodingKey {
            case type, text, attachments, replay, mode, quotes, screen
            case turnID = "turn_id"
            case attachmentIDs = "attachment_ids"
            case parentID = "parent_id"
            case editMessageID = "edit_message_id"
            case titleText = "title_text"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch command {
            case let .turn(turn):
                try container.encode("turn", forKey: .type)
                try container.encode(turn.turnID, forKey: .turnID)
                try container.encode(turn.text, forKey: .text)
                try container.encode(turn.attachments, forKey: .attachments)
                try container.encode(turn.replay, forKey: .replay)
                if let start = turn.start { try Self.encode(start, into: &container) }
            case .cancel:
                try container.encode("cancel", forKey: .type)
            case .close:
                try container.encode("close", forKey: .type)
            }
        }

        private static func encode(_ start: ChatTurnStart, into container: inout KeyedEncodingContainer<CodingKeys>) throws {
            try container.encode(start.mode.rawValue, forKey: .mode)
            if !start.attachmentIDs.isEmpty { try container.encode(start.attachmentIDs, forKey: .attachmentIDs) }
            try container.encodeIfPresent(start.parentID, forKey: .parentID)
            try container.encodeIfPresent(start.editMessageID, forKey: .editMessageID)
            if !start.quotes.isEmpty { try container.encode(start.quotes, forKey: .quotes) }
            try container.encodeIfPresent(start.titleText, forKey: .titleText)
            if let screen = start.screen, !screen.isEmpty { try container.encode(screen, forKey: .screen) }
        }
    }
}

/// Whether a provider session has seen the history a turn builds on.
/// `continuousLeafID` is the last message the live session answered; nil for
/// a new session, which has seen nothing (sessions never resume, #604 G11).
package enum ChatContinuity {
    /// `historyTipID` is the parent of the user message being sent.
    package static func replayNeeded(historyTipID: Int64?, continuousLeafID: Int64?) -> Bool {
        historyTipID != continuousLeafID
    }
}

/// The text a turn sends (spec §4.3): the actions-outcome block and, from the
/// help popup, the current-screen block are prefixed at send time only (the
/// screen block goes first). The REFERENCED block is already part of the stored
/// user text (Task 25's composer — preflight ruling A31), so it is not added
/// here.
package enum ChatTurnText {
    package static func compose(userText: String, outcomes: String?, screen: ScreenContext? = nil) -> String {
        var text = userText
        if let outcomes, !outcomes.isEmpty { text = outcomes + "\n\n" + text }
        if let screen { text = screen.block + "\n\n" + text }
        return text
    }
}

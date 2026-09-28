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
    /// the history from `chat_messages` (spec §2.4). Regenerate/edit insert
    /// their new rows (with this NEW `turnID`) before the turn is sent.
    package let replay: Bool

    package init(turnID: String, text: String, attachments: [ChatCommandAttachment], replay: Bool) {
        self.turnID = turnID
        self.text = text
        self.attachments = attachments
        self.replay = replay
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
            case type, text, attachments, replay
            case turnID = "turn_id"
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
            case .cancel:
                try container.encode("cancel", forKey: .type)
            case .close:
                try container.encode("close", forKey: .type)
            }
        }
    }
}

/// What a view model asks a session client to run.
package struct ChatTurnRequest: Equatable, Sendable {
    package let command: ChatTurnCommand
    /// The `partial` assistant row created before sending (CHAT-01).
    package let assistantMessageID: Int64

    package init(command: ChatTurnCommand, assistantMessageID: Int64) {
        self.command = command
        self.assistantMessageID = assistantMessageID
    }
}

/// Whether a provider session has seen the history a turn builds on.
/// `continuousLeafID` is the last message the live session answered — or,
/// for a session spawned with `--resume`, the conversation's leaf at spawn.
package enum ChatContinuity {
    package static func initialLeaf(resumeSessionID: String?, activeLeafID: Int64?) -> Int64? {
        guard let resumeSessionID, !resumeSessionID.isEmpty else { return nil }
        return activeLeafID
    }

    /// `historyTipID` is the parent of the user message being sent.
    package static func replayNeeded(historyTipID: Int64?, continuousLeafID: Int64?) -> Bool {
        historyTipID != continuousLeafID
    }
}

/// The text a turn sends (spec §4.3): the actions-outcome block is prefixed
/// at send time only. The REFERENCED block is already part of the stored
/// user text (Task 25's composer — preflight ruling A31), so it is not added
/// here.
package enum ChatTurnText {
    package static func compose(userText: String, outcomes: String?) -> String {
        guard let outcomes, !outcomes.isEmpty else { return userText }
        return outcomes + "\n\n" + userText
    }
}

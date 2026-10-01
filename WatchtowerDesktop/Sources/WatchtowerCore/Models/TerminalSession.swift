import Foundation
import GRDB

/// One `terminal_sessions` row (goose migration 00084): a named, resumable
/// embedded terminal — a Claude Code session or a plain shell. `projectID`
/// nil is a standalone terminal. The Desktop writes every column; Go writes
/// only an AI-generated title (`watchtower terminal title`).
package struct TerminalSession: Codable, FetchableRecord, Identifiable, Equatable, Sendable {
    package enum Kind: String, Codable, Sendable { case claude, shell }
    package enum TitleSource: String, Codable, Sendable { case auto, ai, user }

    package var id: Int64
    package var projectID: Int64?
    package var kind: Kind
    package var title: String
    package var titleSource: TitleSource
    package var targetID: Int64?
    package var folderPath: String
    package var claudeSessionID: String?
    package var createdAt: String
    package var lastActiveAt: String
    // `closed_at` is a legacy column, no longer read or written: the Close
    // action was removed, so every row is just running or not running.

    package enum CodingKeys: String, CodingKey {
        case id, kind, title
        case projectID = "project_id"
        case titleSource = "title_source"
        case targetID = "target_id"
        case folderPath = "folder_path"
        case claudeSessionID = "claude_session_id"
        case createdAt = "created_at"
        case lastActiveAt = "last_active_at"
    }
}

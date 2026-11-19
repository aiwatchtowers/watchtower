import Foundation

/// Decoded `watchtower watchman profile --workbench N --json`
/// (`cmd/watchman_profile.go`, keys pinned by
/// `TestWatchmanProfile_JSONKeysPinned`): what Watchman learned on one
/// workbench, a text per decision category plus the sleep window.
package struct WatchmanProfile: Decodable, Equatable, Sendable {
    package let workbench: Int64
    package let entries: [WatchmanProfileEntry]

    enum CodingKeys: String, CodingKey {
        case workbench
        case entries = "profiles"
    }

    package init(workbench: Int64, entries: [WatchmanProfileEntry]) {
        self.workbench = workbench
        self.entries = entries
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workbench = try container.decode(Int64.self, forKey: .workbench)
        // A nil Go slice marshals to null: no entries, not a decode failure.
        entries = try container.decodeIfPresent([WatchmanProfileEntry].self, forKey: .entries) ?? []
    }

    /// The category entries (the sleep window has its own section).
    package var categories: [WatchmanProfileEntry] {
        entries.filter { $0.key != WatchmanProfileEntry.sleepWindowKey }
    }
}

package struct WatchmanProfileEntry: Decodable, Equatable, Sendable {
    /// The profile key of the sleep window (`watchman.SleepWindowKey`).
    package static let sleepWindowKey = "sleep_window"
    /// A category text holds at most this many lines (`watchman.ProfileMaxLines`).
    package static let maxLines = 20

    package let key: String
    package let text: String
    /// Set by the owner: the weekly rebuild leaves it until he unpins it.
    package let pinned: Bool
    /// RFC 3339, UTC.
    package let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case key, text, pinned
        case updatedAt = "updated_at"
    }

    package init(key: String, text: String, pinned: Bool, updatedAt: String) {
        (self.key, self.text, self.pinned, self.updatedAt) = (key, text, pinned, updatedAt)
    }

    /// The text's rule lines, blanks dropped.
    package var lines: [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Decoded `watchtower watchman limits list --json` (`cmd/watchman_limits.go`,
/// keys pinned by `TestWatchmanLimits_JSONKeysPinned`): the built-in
/// hard-limit table, which cannot be removed, and the owner's own rows.
package struct WatchmanLimits: Decodable, Equatable, Sendable {
    /// The built-in rows by name (`main_ref`, `outward`, …); they have no id.
    package let builtin: [String]
    package let owner: [WatchmanOwnerLimit]

    package init(builtin: [String], owner: [WatchmanOwnerLimit]) {
        (self.builtin, self.owner) = (builtin, owner)
    }

    enum CodingKeys: String, CodingKey { case builtin, owner }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        builtin = try container.decodeIfPresent([String].self, forKey: .builtin) ?? []
        owner = try container.decodeIfPresent([WatchmanOwnerLimit].self, forKey: .owner) ?? []
    }

    /// Every row in the order the screen lists them: the owner's first
    /// (removable), then the built-in ones (no id, read-only).
    package var rows: [WatchmanLimitRow] {
        owner.map { WatchmanLimitRow(removableID: $0.id, kind: WatchmanLimitKind(rawValue: $0.kind), text: $0.pattern) }
            + builtin.map { WatchmanLimitRow(removableID: nil, kind: nil, text: $0) }
    }
}

package struct WatchmanOwnerLimit: Decodable, Equatable, Sendable {
    package let id: Int64
    package let kind: String
    package let pattern: String

    package init(id: Int64, kind: String, pattern: String) {
        (self.id, self.kind, self.pattern) = (id, kind, pattern)
    }
}

/// One row of the limits list: an owner's row carries the id `limits
/// remove` takes; a built-in row has none, so it has no Remove.
package struct WatchmanLimitRow: Equatable, Sendable {
    package let removableID: Int64?
    /// The owner row's kind; nil for a built-in row.
    package let kind: WatchmanLimitKind?
    /// The owner's pattern, or the built-in row's name.
    package let text: String

    package var isBuiltin: Bool { removableID == nil }
}

/// The kinds `watchman limits add --kind` accepts (`watchman.ExtraLimitCommand`,
/// `watchman.ExtraLimitTool`).
package enum WatchmanLimitKind: String, CaseIterable, Equatable, Sendable {
    case command, tool
}

/// Where an edit's error line shows: under a profile entry (the sleep
/// window is the entry `sleep_window`) or under the limits list.
package enum WatchmanEditSlot: Hashable, Sendable {
    case profile(workbench: Int64, key: String)
    case limits
}

/// What Settings → Watchman shows beside the status: each learned
/// workbench's profile, the limits, and the lines of failed reads and edits.
package struct WatchmanEditingData: Equatable, Sendable {
    package var profiles: [Int64: WatchmanProfile] = [:]
    package var profileReadErrors: [Int64: String] = [:]
    package var limits: WatchmanLimits?
    package var limitsReadError: String?
    package var errors: [WatchmanEditSlot: String] = [:]
    /// Edits the CLI runs now; their controls are disabled.
    package var saving: Set<WatchmanEditSlot> = []

    /// The workbench's first profile read is still in flight.
    package func isLoadingProfile(_ workbench: Int64) -> Bool {
        profiles[workbench] == nil && profileReadErrors[workbench] == nil
    }

    package init(
        profiles: [Int64: WatchmanProfile] = [:],
        limits: WatchmanLimits? = nil,
        errors: [WatchmanEditSlot: String] = [:]
    ) {
        (self.profiles, self.limits, self.errors) = (profiles, limits, errors)
    }
}

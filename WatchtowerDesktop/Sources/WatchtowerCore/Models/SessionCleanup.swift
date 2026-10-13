import Foundation

/// What `watchtower workbench cleanup --json` prints (Go's
/// `sessioncleanup.Result`, spec 2026-10-12-session-cleanup-design §4.1):
/// a plan (`mode: "plan"`) or an apply's result (`mode: "apply"`). The same
/// JSON is stored in `terminal_sessions.cleanup_result`. Decoding is
/// tolerant: a missing field takes its zero value (a missing `*_known` is
/// false: an absent measurement is not a known size), and an unknown kind,
/// action or reason decodes to its `.unknown(raw)` case rather than failing
/// the whole plan — a newer CLI never blanks the Desktop's sheet.
package struct SessionCleanupPlan: Decodable, Equatable, Sendable {
    package var sessionID: Int64
    package var workbenchID: Int64
    /// "plan" or "apply".
    package var mode: String
    package var sweep: Bool
    package var items: [SessionCleanupItem]
    package var defaultBranch: String
    package var removedBytes: Int64
    /// False when a removed worktree was not measured: `removedBytes` is
    /// then a lower bound.
    package var removedBytesKnown: Bool
    /// Go's English summary line (`sessioncleanup.Summarize`).
    package var summary: String
    package var resultSaved: Bool
    package var resultError: String

    package init(
        sessionID: Int64 = 0,
        workbenchID: Int64 = 0,
        mode: String = "plan",
        sweep: Bool = false,
        items: [SessionCleanupItem] = [],
        defaultBranch: String = "",
        removedBytes: Int64 = 0,
        removedBytesKnown: Bool = true,
        summary: String = "",
        resultSaved: Bool = false,
        resultError: String = ""
    ) {
        self.sessionID = sessionID
        self.workbenchID = workbenchID
        self.mode = mode
        self.sweep = sweep
        self.items = items
        self.defaultBranch = defaultBranch
        self.removedBytes = removedBytes
        self.removedBytesKnown = removedBytesKnown
        self.summary = summary
        self.resultSaved = resultSaved
        self.resultError = resultError
    }

    package enum CodingKeys: String, CodingKey {
        case mode, sweep, items, summary
        case sessionID = "session_id"
        case workbenchID = "workbench_id"
        case defaultBranch = "default_branch"
        case removedBytes = "removed_bytes"
        case removedBytesKnown = "removed_bytes_known"
        case resultSaved = "result_saved"
        case resultError = "result_error"
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.decodeIfPresent(Int64.self, forKey: .sessionID) ?? 0
        workbenchID = try c.decodeIfPresent(Int64.self, forKey: .workbenchID) ?? 0
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? ""
        sweep = try c.decodeIfPresent(Bool.self, forKey: .sweep) ?? false
        items = try c.decodeIfPresent([SessionCleanupItem].self, forKey: .items) ?? []
        defaultBranch = try c.decodeIfPresent(String.self, forKey: .defaultBranch) ?? ""
        removedBytes = try c.decodeIfPresent(Int64.self, forKey: .removedBytes) ?? 0
        removedBytesKnown = try c.decodeIfPresent(Bool.self, forKey: .removedBytesKnown) ?? false
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        resultSaved = try c.decodeIfPresent(Bool.self, forKey: .resultSaved) ?? false
        resultError = try c.decodeIfPresent(String.self, forKey: .resultError) ?? ""
    }

    /// The keys of the items the plan would remove — what an apply of this
    /// plan names with `--item`.
    package var removableKeys: [String] {
        items.filter(\.isPendingRemoval).map(\.key)
    }
}

/// One thing a plan would remove or keeps, with why (Go's
/// `sessioncleanup.Item`).
package struct SessionCleanupItem: Decodable, Equatable, Identifiable, Sendable {
    package enum Kind: Equatable, Hashable, Sendable {
        case worktree, branch, process, lsreg
        case unknown(String)

        package init(raw: String) {
            switch raw {
            case "worktree": self = .worktree
            case "branch": self = .branch
            case "process": self = .process
            case "lsreg": self = .lsreg
            default: self = .unknown(raw)
            }
        }
    }

    package enum Action: Equatable, Hashable, Sendable {
        case remove, keep
        case unknown(String)

        package init(raw: String) {
            switch raw {
            case "remove": self = .remove
            case "keep": self = .keep
            default: self = .unknown(raw)
            }
        }
    }

    /// The opaque key an apply names with `--item`.
    package var key: String
    package var kind: Kind
    /// A worktree's path, a branch's name, a process's name, a bundle path.
    package var name: String
    package var branch: String
    package var bytes: Int64
    package var bytesKnown: Bool
    package var action: Action
    /// Nil when the item has none (a removable item).
    package var reason: SessionCleanupReason?
    package var detail: String
    /// Removed by an apply.
    package var done: Bool
    package var error: String
    /// Sweep only: whose the item probably is.
    package var owner: SessionCleanupOwner?

    package var id: String { key }

    /// Still to remove: planned for removal, neither done nor failed.
    package var isPendingRemoval: Bool { action == .remove && !done && error.isEmpty }

    package init(
        key: String,
        kind: Kind,
        name: String = "",
        branch: String = "",
        bytes: Int64 = 0,
        bytesKnown: Bool = true,
        action: Action,
        reason: SessionCleanupReason? = nil,
        detail: String = "",
        done: Bool = false,
        error: String = "",
        owner: SessionCleanupOwner? = nil
    ) {
        self.key = key
        self.kind = kind
        self.name = name
        self.branch = branch
        self.bytes = bytes
        self.bytesKnown = bytesKnown
        self.action = action
        self.reason = reason
        self.detail = detail
        self.done = done
        self.error = error
        self.owner = owner
    }

    package enum CodingKeys: String, CodingKey {
        case key, kind, name, branch, bytes, action, reason, detail, done, error, owner
        case bytesKnown = "bytes_known"
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        kind = Kind(raw: try c.decodeIfPresent(String.self, forKey: .kind) ?? "")
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? ""
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
        bytesKnown = try c.decodeIfPresent(Bool.self, forKey: .bytesKnown) ?? false
        action = Action(raw: try c.decodeIfPresent(String.self, forKey: .action) ?? "")
        let code = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        reason = code.isEmpty ? nil : SessionCleanupReason(code: code)
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
        owner = try c.decodeIfPresent(SessionCleanupOwner.self, forKey: .owner)
    }
}

/// Why an item is kept (or what an apply did instead), as Go's
/// `sessioncleanup.Reason*` codes. A code this build does not know is
/// `.unknown(code)`, shown as the code in words.
package enum SessionCleanupReason: Equatable, Hashable, Sendable {
    case known(Code)
    case unknown(String)

    /// Every reason code Go's `internal/sessioncleanup` emits.
    package enum Code: String, CaseIterable, Sendable {
        // Catches (catches.go).
        case mainFolder = "main_folder"
        case workbenchFolder = "workbench_folder"
        case locked
        case uncommittedChanges = "uncommitted_changes"
        case processRunning = "process_running"
        case processUnknown = "process_unknown"
        case sessionInIt = "session_in_it"
        case youAreInIt = "you_are_in_it"
        case unpushedCommits = "unpushed_commits"
        case operationInProgress = "operation_in_progress"
        case defaultBranch = "default_branch"
        case defaultBranchUnknown = "default_branch_unknown"
        case checkedOut = "checked_out"
        case claudeHome = "claude_home"
        case notAWorktree = "not_a_worktree"
        case notABranch = "not_a_branch"
        case sessionRecent = "session_recent"
        case checkFailed = "check_failed"
        case containsWorktree = "contains_worktree"
        // Ownership (ownership.go).
        case notThisSession = "not_this_session"
        case existedBeforeSession = "existed_before_session"
        case createdUnknown = "created_unknown"
        // Apply (apply.go).
        case gitRefused = "git_refused"
        case moved
        case notSelected = "not_selected"
        case notInPlan = "not_in_plan"
        case notAttempted = "not_attempted"
        case worktreeKept = "worktree_kept"
        case bundleExists = "bundle_exists"
        case bundleUnreadable = "bundle_unreadable"
    }

    package init(code: String) {
        self = Code(rawValue: code).map(Self.known) ?? .unknown(code)
    }

    /// The wire code.
    package var code: String {
        switch self {
        case let .known(known): known.rawValue
        case let .unknown(raw): raw
        }
    }
}

/// The sweep's guess at whose an item is (Go's `sessioncleanup.OwnerHint`):
/// the session that recorded it, or unknown (a pre-feature or deleted
/// session).
package struct SessionCleanupOwner: Decodable, Equatable, Sendable {
    /// Nil when unknown.
    package var sessionID: Int64?
    package var title: String
    /// RFC 3339; "" when unknown.
    package var lastActive: String
    package var isUnknown: Bool

    package init(sessionID: Int64? = nil, title: String = "", lastActive: String = "", isUnknown: Bool = false) {
        self.sessionID = sessionID
        self.title = title
        self.lastActive = lastActive
        self.isUnknown = isUnknown
    }

    package enum CodingKeys: String, CodingKey {
        case title
        case sessionID = "session_id"
        case lastActive = "last_active"
        case isUnknown = "unknown"
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decodeIfPresent(Int64.self, forKey: .sessionID) ?? 0
        sessionID = id > 0 ? id : nil
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        lastActive = try c.decodeIfPresent(String.self, forKey: .lastActive) ?? ""
        isUnknown = try c.decodeIfPresent(Bool.self, forKey: .isUnknown) ?? false
    }
}

/// A session's stored cleanup outcome (migration 00111):
/// `terminal_sessions.cleanup_result` — the apply's JSON, decoded tolerantly
/// — and `cleanup_at`. Read by `TerminalSessionQueries.fetchCleanupRecord`,
/// kept out of `TerminalSession` as Go keeps the columns out of
/// `GetTerminalSession`.
package struct SessionCleanupRecord: Equatable, Sendable {
    /// Nil when the stored JSON does not decode as a result.
    package var result: SessionCleanupPlan?
    /// The stamp Go wrote with the result; "" when none.
    package var at: String

    package init(result: SessionCleanupPlan?, at: String) {
        self.result = result
        self.at = at
    }
}

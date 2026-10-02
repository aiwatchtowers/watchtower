import Foundation

/// `watchtower workbench git status --workbench N --json` (board target #233).
/// Go owns git (`internal/workbenchgit`); the Desktop never runs it and only
/// decodes and shows this. `git` is the one key every CLI sends; the rest
/// default, so an older or partial envelope still decodes. `git == false`
/// (not a work tree, or no git binary — `gitAvailable == false`) hides the
/// branch button; `note` says why.
package struct WorkbenchGitStatus: Decodable, Equatable, Sendable {
    package var workbenchID: Int64
    package var gitAvailable: Bool
    package var git: Bool
    package var note: String
    package var branch: String
    package var detached: Bool
    /// A repository with no commit yet: `branch` is the name HEAD points at.
    package var unborn: Bool
    /// Short hash of HEAD; empty on an unborn branch.
    package var head: String
    package var upstream: String
    package var ahead: Int
    package var behind: Int
    /// Any staged, unstaged or untracked entry (ignored files excluded).
    package var dirty: Bool
    package var changes: Int
    /// `merge|rebase|cherry-pick|revert|bisect`, or empty.
    package var operation: String
    package var topLevel: String
    /// This worktree's git dir and the repository's common dir — what the
    /// refs watcher watches (equal outside a linked worktree).
    package var gitDir: String
    package var commonDir: String
    /// `git status` itself failed; the fields above it are partly unknown.
    package var statusOK: Bool
    package var statusError: String

    package init(
        workbenchID: Int64 = 0,
        gitAvailable: Bool = true,
        git: Bool = true,
        note: String = "",
        branch: String = "",
        detached: Bool = false,
        unborn: Bool = false,
        head: String = "",
        upstream: String = "",
        ahead: Int = 0,
        behind: Int = 0,
        dirty: Bool = false,
        changes: Int = 0,
        operation: String = "",
        topLevel: String = "",
        gitDir: String = "",
        commonDir: String = "",
        statusOK: Bool = true,
        statusError: String = ""
    ) {
        self.workbenchID = workbenchID
        self.gitAvailable = gitAvailable
        self.git = git
        self.note = note
        self.branch = branch
        self.detached = detached
        self.unborn = unborn
        self.head = head
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.dirty = dirty
        self.changes = changes
        self.operation = operation
        self.topLevel = topLevel
        self.gitDir = gitDir
        self.commonDir = commonDir
        self.statusOK = statusOK
        self.statusError = statusError
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        git = try c.decode(Bool.self, forKey: .git)
        workbenchID = try c.decodeIfPresent(Int64.self, forKey: .workbenchID) ?? 0
        // Without the key the CLI predates the no-git case: git ran.
        gitAvailable = try c.decodeIfPresent(Bool.self, forKey: .gitAvailable) ?? true
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? ""
        detached = try c.decodeIfPresent(Bool.self, forKey: .detached) ?? false
        unborn = try c.decodeIfPresent(Bool.self, forKey: .unborn) ?? false
        head = try c.decodeIfPresent(String.self, forKey: .head) ?? ""
        upstream = try c.decodeIfPresent(String.self, forKey: .upstream) ?? ""
        ahead = try c.decodeIfPresent(Int.self, forKey: .ahead) ?? 0
        behind = try c.decodeIfPresent(Int.self, forKey: .behind) ?? 0
        dirty = try c.decodeIfPresent(Bool.self, forKey: .dirty) ?? false
        changes = try c.decodeIfPresent(Int.self, forKey: .changes) ?? 0
        operation = try c.decodeIfPresent(String.self, forKey: .operation) ?? ""
        topLevel = try c.decodeIfPresent(String.self, forKey: .topLevel) ?? ""
        gitDir = try c.decodeIfPresent(String.self, forKey: .gitDir) ?? ""
        commonDir = try c.decodeIfPresent(String.self, forKey: .commonDir) ?? ""
        statusOK = try c.decodeIfPresent(Bool.self, forKey: .statusOK) ?? true
        statusError = try c.decodeIfPresent(String.self, forKey: .statusError) ?? ""
    }

    package enum CodingKeys: String, CodingKey {
        case git, note, branch, detached, unborn, head, upstream, ahead, behind, dirty, changes, operation
        case workbenchID = "workbench_id"
        case gitAvailable = "git_available"
        case topLevel = "top_level"
        case gitDir = "git_dir"
        case commonDir = "common_dir"
        case statusOK = "status_ok"
        case statusError = "status_error"
    }
}

/// One local branch of `workbench git branches --json`, newest commit first.
package struct WorkbenchGitBranch: Decodable, Equatable, Sendable, Identifiable {
    package var name: String
    package var current: Bool
    package var head: String
    /// The branch tip's committer date; nil when the CLI sent none or one
    /// that is not RFC3339.
    package var committedAt: Date?
    package var upstream: String
    package var ahead: Int
    package var behind: Int
    /// Set only when the branch is checked out in ANOTHER worktree — the
    /// switch is refused there, so the row is disabled.
    package var worktree: String
    package var worktreeName: String

    package var id: String { name }

    package init(
        name: String,
        current: Bool = false,
        head: String = "",
        committedAt: Date? = nil,
        upstream: String = "",
        ahead: Int = 0,
        behind: Int = 0,
        worktree: String = "",
        worktreeName: String = ""
    ) {
        self.name = name
        self.current = current
        self.head = head
        self.committedAt = committedAt
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.worktree = worktree
        self.worktreeName = worktreeName
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        current = try c.decodeIfPresent(Bool.self, forKey: .current) ?? false
        head = try c.decodeIfPresent(String.self, forKey: .head) ?? ""
        let stamp = try c.decodeIfPresent(String.self, forKey: .committedAt) ?? ""
        committedAt = Self.parseTime(stamp)
        upstream = try c.decodeIfPresent(String.self, forKey: .upstream) ?? ""
        ahead = try c.decodeIfPresent(Int.self, forKey: .ahead) ?? 0
        behind = try c.decodeIfPresent(Int.self, forKey: .behind) ?? 0
        worktree = try c.decodeIfPresent(String.self, forKey: .worktree) ?? ""
        worktreeName = try c.decodeIfPresent(String.self, forKey: .worktreeName) ?? ""
    }

    package enum CodingKeys: String, CodingKey {
        case name, current, head, upstream, ahead, behind, worktree
        case committedAt = "committed_at"
        case worktreeName = "worktree_name"
    }

    /// Go writes RFC3339 in UTC (`time.RFC3339`); the formatter pins UTC so
    /// a stamp without an offset never reads as local time.
    static func parseTime(_ stamp: String) -> Date? {
        guard !stamp.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: stamp) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: stamp)
    }
}

/// `workbench git branches --workbench N --json`. `branchesOK == false` means
/// the listing failed (`branchesError`); `branches` is then empty.
package struct WorkbenchGitBranches: Decodable, Equatable, Sendable {
    package var workbenchID: Int64
    package var gitAvailable: Bool
    package var git: Bool
    package var current: String
    package var branches: [WorkbenchGitBranch]
    package var branchesOK: Bool
    package var branchesError: String

    package init(
        workbenchID: Int64 = 0,
        gitAvailable: Bool = true,
        git: Bool = true,
        current: String = "",
        branches: [WorkbenchGitBranch] = [],
        branchesOK: Bool = true,
        branchesError: String = ""
    ) {
        self.workbenchID = workbenchID
        self.gitAvailable = gitAvailable
        self.git = git
        self.current = current
        self.branches = branches
        self.branchesOK = branchesOK
        self.branchesError = branchesError
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        git = try c.decode(Bool.self, forKey: .git)
        workbenchID = try c.decodeIfPresent(Int64.self, forKey: .workbenchID) ?? 0
        gitAvailable = try c.decodeIfPresent(Bool.self, forKey: .gitAvailable) ?? true
        current = try c.decodeIfPresent(String.self, forKey: .current) ?? ""
        branches = try c.decodeIfPresent([WorkbenchGitBranch].self, forKey: .branches) ?? []
        branchesOK = try c.decodeIfPresent(Bool.self, forKey: .branchesOK) ?? true
        branchesError = try c.decodeIfPresent(String.self, forKey: .branchesError) ?? ""
    }

    package enum CodingKeys: String, CodingKey {
        case git, current, branches
        case workbenchID = "workbench_id"
        case gitAvailable = "git_available"
        case branchesOK = "branches_ok"
        case branchesError = "branches_error"
    }
}

/// `workbench git switch|create --json`. Every refusal arrives as exit 0
/// with this envelope (`ProcessCLIRunner` drops stdout on a non-zero exit):
/// `needsConfirmation` asks the owner first (resend with `--stash` /
/// `--confirm-agent`), `refused` cannot be overridden, `error` is git's own
/// stderr. Go decides every guard; the Desktop only resends what the owner
/// confirmed.
package struct WorkbenchGitSwitchResult: Decodable, Equatable, Sendable {
    package enum Confirmation: String, Sendable, Equatable {
        case uncommittedChanges = "uncommitted_changes"
        case agentRunning = "agent_running"
    }

    package var workbenchID: Int64
    package var branch: String
    package var switched: Bool
    /// Already on the branch: nothing was written.
    package var already: Bool
    /// `create` only.
    package var created: Bool
    package var needsConfirmation: [Confirmation]
    /// `needs_confirmation` values this app does not know (a newer CLI's
    /// guard): the switch did not happen and cannot be confirmed from here.
    package var unknownConfirmations: [String]
    package var changes: Int
    package var refused: String
    package var refusedDetail: String
    /// The stash ref this run pushed (never popped after a switch).
    package var stashed: String
    package var stashMessage: String
    /// The switch failed after the stash and the stash was put back.
    package var stashRestored: Bool
    package var error: String
    /// The status after the call; nil when the CLI sent none (or `{}`).
    package var status: WorkbenchGitStatus?

    package init(
        workbenchID: Int64 = 0,
        branch: String = "",
        switched: Bool = false,
        already: Bool = false,
        created: Bool = false,
        needsConfirmation: [Confirmation] = [],
        unknownConfirmations: [String] = [],
        changes: Int = 0,
        refused: String = "",
        refusedDetail: String = "",
        stashed: String = "",
        stashMessage: String = "",
        stashRestored: Bool = false,
        error: String = "",
        status: WorkbenchGitStatus? = nil
    ) {
        self.workbenchID = workbenchID
        self.branch = branch
        self.switched = switched
        self.already = already
        self.created = created
        self.needsConfirmation = needsConfirmation
        self.unknownConfirmations = unknownConfirmations
        self.changes = changes
        self.refused = refused
        self.refusedDetail = refusedDetail
        self.stashed = stashed
        self.stashMessage = stashMessage
        self.stashRestored = stashRestored
        self.error = error
        self.status = status
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switched = try c.decode(Bool.self, forKey: .switched)
        workbenchID = try c.decodeIfPresent(Int64.self, forKey: .workbenchID) ?? 0
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? ""
        already = try c.decodeIfPresent(Bool.self, forKey: .already) ?? false
        created = try c.decodeIfPresent(Bool.self, forKey: .created) ?? false
        let needs = try c.decodeIfPresent([String].self, forKey: .needsConfirmation) ?? []
        needsConfirmation = needs.compactMap(Confirmation.init(rawValue:))
        unknownConfirmations = needs.filter { Confirmation(rawValue: $0) == nil }
        changes = try c.decodeIfPresent(Int.self, forKey: .changes) ?? 0
        refused = try c.decodeIfPresent(String.self, forKey: .refused) ?? ""
        refusedDetail = try c.decodeIfPresent(String.self, forKey: .refusedDetail) ?? ""
        stashed = try c.decodeIfPresent(String.self, forKey: .stashed) ?? ""
        stashMessage = try c.decodeIfPresent(String.self, forKey: .stashMessage) ?? ""
        stashRestored = try c.decodeIfPresent(Bool.self, forKey: .stashRestored) ?? false
        error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
        // `{}` is "no status", not a status with `git` missing; anything
        // else must decode, so a malformed status still fails loudly.
        if c.contains(.status),
           try !c.decodeNil(forKey: .status),
           try !c.nestedContainer(keyedBy: WorkbenchGitStatus.CodingKeys.self, forKey: .status).allKeys.isEmpty {
            status = try c.decode(WorkbenchGitStatus.self, forKey: .status)
        } else {
            status = nil
        }
    }

    package enum CodingKeys: String, CodingKey {
        case branch, switched, already, created, changes, refused, stashed, error, status
        case workbenchID = "workbench_id"
        case needsConfirmation = "needs_confirmation"
        case refusedDetail = "refused_detail"
        case stashMessage = "stash_message"
        case stashRestored = "stash_restored"
    }
}

/// A board target carrying a branch (`targets.branch`), for the branch
/// popover's `#id` badge. Read from the DB when the popover opens.
package struct WorkbenchBranchTarget: Equatable, Sendable {
    package let id: Int64
    package let title: String
    package let status: String

    package init(id: Int64, title: String, status: String) {
        self.id = id
        self.title = title
        self.status = status
    }
}

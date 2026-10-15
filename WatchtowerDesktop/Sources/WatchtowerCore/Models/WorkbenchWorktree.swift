import Foundation

/// `watchtower workbench worktree create|ensure --json` (Go's
/// `workbenchgit.WorktreeResult` plus the command's `integration_error`).
/// Every key defaults when missing, so an older CLI still decodes.
package struct WorktreeCreateResult: Decodable, Equatable, Sendable {
    package let workbenchID: Int64
    package let created: Bool
    /// The worktree's top level.
    package let path: String
    /// `path` plus the workbench folder's prefix: where the session starts.
    package let cwd: String
    /// `wt/<slug>`.
    package let branch: String
    /// Full id of the commit the branch was cut from.
    package let base: String
    /// Empty when the base was a detached HEAD.
    package let baseBranch: String
    package let baseDirty: Bool
    package let included: [String]
    package let includeWarnings: [String]
    /// A refusal code (e.g. `unborn`); empty when the worktree was made.
    package let refused: String
    package let refusedDetail: String
    package let error: String
    /// A failure after the worktree existed: it is usable.
    package let warning: String
    package let integrationError: String

    private enum CodingKeys: String, CodingKey {
        case workbenchID = "workbench_id"
        case created, path, cwd, branch, base
        case baseBranch = "base_branch"
        case baseDirty = "base_dirty"
        case included
        case includeWarnings = "include_warnings"
        case refused
        case refusedDetail = "refused_detail"
        case error, warning
        case integrationError = "integration_error"
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workbenchID = try c.decodeIfPresent(Int64.self, forKey: .workbenchID) ?? 0
        created = try c.decodeIfPresent(Bool.self, forKey: .created) ?? false
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? ""
        base = try c.decodeIfPresent(String.self, forKey: .base) ?? ""
        baseBranch = try c.decodeIfPresent(String.self, forKey: .baseBranch) ?? ""
        baseDirty = try c.decodeIfPresent(Bool.self, forKey: .baseDirty) ?? false
        included = try c.decodeIfPresent([String].self, forKey: .included) ?? []
        includeWarnings = try c.decodeIfPresent([String].self, forKey: .includeWarnings) ?? []
        refused = try c.decodeIfPresent(String.self, forKey: .refused) ?? ""
        refusedDetail = try c.decodeIfPresent(String.self, forKey: .refusedDetail) ?? ""
        error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
        warning = try c.decodeIfPresent(String.self, forKey: .warning) ?? ""
        integrationError = try c.decodeIfPresent(String.self, forKey: .integrationError) ?? ""
    }
}

/// `watchtower workbench worktree forget --json`.
package struct WorktreeForgetResult: Decodable, Equatable, Sendable {
    package let workbenchID: Int64
    package let forgot: Bool
    package let error: String

    private enum CodingKeys: String, CodingKey {
        case workbenchID = "workbench_id"
        case forgot, error
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workbenchID = try c.decodeIfPresent(Int64.self, forKey: .workbenchID) ?? 0
        forgot = try c.decodeIfPresent(Bool.self, forKey: .forgot) ?? false
        error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
    }
}

import Foundation
import WatchtowerCore

/// A refusal code of the multi-folder workbench's CLI verbs and MCP tools
/// (plan Global Constraints, spec D42): Go's `--json` results carry it as
/// `error_code`, its text as `error` (`"<code>: <sentence>"`).
enum WorkbenchRefusalCode: String, CaseIterable, Equatable, Sendable {
    case alreadyHere = "already_here"
    case otherBench = "other_bench"
    case nested
    case notFound = "not_found"
    case notInstalled = "not_installed"
    case folderMissing = "folder_missing"
    case folderRemoved = "folder_removed"
    case sessionsRunning = "sessions_running"
    case lastFolder = "last_folder"
    case limit
    case tooLong = "too_long"
    case notRunning = "not_running"
    case notSameWorkbench = "not_same_workbench"
    case `self`
    case declined
    /// The CLI's own: a folder no workbench may have (root, home, Watchtower's data).
    case notAllowed = "not_allowed"
    /// The CLI's own: a flag value the verb does not take.
    case badArgs = "bad_args"

    /// The code a refusal's `"<code>: <sentence>"` text starts with; nil for
    /// any other text.
    init?(prefixOf text: String) {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        self.init(rawValue: String(text[..<colon]))
    }
}

/// Who put a folder on the bench (`workbench_folders.added_by`).
enum FolderAddedBy: String, Equatable, Sendable {
    case owner
    case agentSuggestion = "agent_suggestion"
}

/// One folder as `workbench folder … --json` prints it.
struct FolderInfo: Decodable, Equatable {
    let id: Int64
    let path: String
    let name: String
    let position: Int
    /// It is `projects.folder_path`.
    let home: Bool
    /// Watchtower's hooks for this workbench are in it.
    let installed: Bool
    /// Taken off the bench.
    let removed: Bool
}

/// `workbench folder add|remove|locate --json`. A refusal is `ok == false`
/// with its `errorCode` (exit 0); `folder` names the folder it refers to
/// when there is one (`already_here`, `nested`). `install` is the install
/// (add, locate) or uninstall (remove) that runs after the write: its
/// failure never undoes the write (spec §7 row 2).
struct FolderResult: Decodable, Equatable {
    struct OtherBench: Decodable, Equatable {
        let id: Int64
        let name: String
    }

    struct Step: Decodable, Equatable {
        let ok: Bool
        let error: String
    }

    let ok: Bool
    /// "" on success; the raw code (a newer CLI may send one `code` does not know).
    let errorCode: String
    let error: String
    let folder: FolderInfo?
    /// `other_bench`: the workbench the folder is on.
    let otherBench: OtherBench?
    let install: Step?

    /// The refusal's code when this build knows it.
    var code: WorkbenchRefusalCode? { WorkbenchRefusalCode(rawValue: errorCode) }

    enum CodingKeys: String, CodingKey {
        case ok, error, folder, install
        case errorCode = "error_code"
        case otherBench = "other_bench"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decode(Bool.self, forKey: .ok)
        errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode) ?? ""
        error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
        folder = try c.decodeIfPresent(FolderInfo.self, forKey: .folder)
        otherBench = try c.decodeIfPresent(OtherBench.self, forKey: .otherBench)
        install = try c.decodeIfPresent(Step.self, forKey: .install)
    }
}

/// The answer of a one-row CLI write that has nothing else to say
/// (`workbench folder quiet|decline`, `workbench message dismiss`): `ok`,
/// else the refusal's code and text.
struct WorkbenchCLIAck: Decodable, Equatable {
    let ok: Bool
    let errorCode: String
    let error: String

    var code: WorkbenchRefusalCode? { WorkbenchRefusalCode(rawValue: errorCode) }

    enum CodingKeys: String, CodingKey {
        case ok, error
        case errorCode = "error_code"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decode(Bool.self, forKey: .ok)
        errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode) ?? ""
        error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
    }
}

/// The bench's folders. The Desktop never writes `workbench_folders`,
/// `workbench_folder_declines` or `session_messages` itself: every change
/// goes through these verbs (Go is the writer, spec §7).
extension WorkbenchCLI {
    /// Puts `path` on the bench and installs Watchtower there.
    func folderAdd(workbenchID: Int64, path: String, addedBy: FolderAddedBy = .owner) async throws -> FolderResult {
        try await folderCall(["add", "--workbench", String(workbenchID), "--folder", path, "--added-by", addedBy.rawValue])
    }

    /// Takes the folder off the bench; only Watchtower's install in it is removed.
    func folderRemove(workbenchID: Int64, folderID: Int64) async throws -> FolderResult {
        try await folderCall(["remove", "--workbench", String(workbenchID), "--folder", String(folderID)])
    }

    /// Points a moved folder at its new path and reinstalls there.
    func folderLocate(workbenchID: Int64, folderID: Int64, to path: String) async throws -> FolderResult {
        try await folderCall(["locate", "--workbench", String(workbenchID), "--folder", String(folderID), "--to", path])
    }

    /// The bench's folders in position order.
    func folderList(workbenchID: Int64, withRemoved: Bool = false) async throws -> [FolderInfo] {
        var args = ["workbench", "folder", "list", "--workbench", String(workbenchID)]
        if withRemoved { args.append("--with-removed") }
        let data = try await runner.run(args: args + ["--json"])
        struct List: Decodable { let folders: [FolderInfo] }
        return try JSONDecoder().decode(List.self, from: data).folders
    }

    /// Not Now on a folder suggestion: the outside-bench hook stays quiet
    /// for `root` in `sessionID` (`session_outside_touches.quiet`).
    func folderQuiet(sessionID: Int64, root: String) async throws -> WorkbenchCLIAck {
        try await ack(["workbench", "folder", "quiet", "--session", String(sessionID), "--root", root])
    }

    /// Never for This Folder: the agent never suggests `path` for this bench again.
    func folderDecline(workbenchID: Int64, path: String) async throws -> WorkbenchCLIAck {
        try await ack(["workbench", "folder", "decline", "--workbench", String(workbenchID), "--folder", path])
    }

    /// Dismiss on the "agent message in the prompt" notice: sets the row's
    /// `prompt_cleared_at` where it is still unset.
    func messageDismiss(id: Int64) async throws -> WorkbenchCLIAck {
        try await ack(["workbench", "message", "dismiss", "--id", String(id)])
    }

    private func folderCall(_ verb: [String]) async throws -> FolderResult {
        let data = try await runner.run(args: ["workbench", "folder"] + verb + ["--json"])
        return try JSONDecoder().decode(FolderResult.self, from: data)
    }

    private func ack(_ args: [String]) async throws -> WorkbenchCLIAck {
        let data = try await runner.run(args: args + ["--json"])
        return try JSONDecoder().decode(WorkbenchCLIAck.self, from: data)
    }
}

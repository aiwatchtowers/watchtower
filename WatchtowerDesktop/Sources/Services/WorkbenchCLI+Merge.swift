import Foundation

/// `workbench merge --from B --into A --json` (#2003, spec §6.13). A refusal
/// is `ok == false` with its code (`sessions_running`: `running` is the
/// count); after a merge, `reinstall.failed` names each place whose
/// reinstall failed — the data moved anyway.
struct BenchMergeResult: Decodable, Equatable {
    struct Failed: Decodable, Equatable {
        let path: String
        let error: String
    }

    struct Reinstall: Decodable, Equatable {
        let ok: Bool
        let failed: [Failed]
    }

    let ok: Bool
    let errorCode: String
    let error: String
    let running: Int
    let movedFolders: [FolderInfo]
    let targets: Int
    let reinstall: Reinstall
    /// The target images' move to the surviving bench's store (best effort;
    /// a failed one leaves them where they were, still shown). Absent = ok.
    let imagesError: String
    /// The surviving bench's re-index of its documents. Absent = ok.
    let indexError: String

    var code: WorkbenchRefusalCode? { WorkbenchRefusalCode(rawValue: errorCode) }
    var reason: String { WorkbenchRefusalCode.sentence(error, code: errorCode) }

    enum CodingKeys: String, CodingKey {
        case ok, error, running, targets, reinstall
        case errorCode = "error_code"
        case movedFolders = "moved_folders"
        case imagesError = "images_error"
        case indexError = "index_error"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decode(Bool.self, forKey: .ok)
        errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode) ?? ""
        error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
        running = try c.decodeIfPresent(Int.self, forKey: .running) ?? 0
        movedFolders = try c.decodeIfPresent([FolderInfo].self, forKey: .movedFolders) ?? []
        targets = try c.decodeIfPresent(Int.self, forKey: .targets) ?? 0
        reinstall = try c.decodeIfPresent(Reinstall.self, forKey: .reinstall) ?? Reinstall(ok: true, failed: [])
        imagesError = try c.decodeIfPresent(String.self, forKey: .imagesError) ?? ""
        indexError = try c.decodeIfPresent(String.self, forKey: .indexError) ?? ""
    }
}

/// `workbench session ensure-install --json`: the launch backstop's answer.
struct SessionEnsureInstallResult: Decodable, Equatable {
    let ok: Bool
    let reinstalled: Bool
    let error: String
}

extension WorkbenchCLI {
    /// Merges bench `from` into bench `into`: its rows move, it leaves the list.
    func merge(from: Int64, into: Int64) async throws -> BenchMergeResult {
        let data = try await runner.run(args: ["workbench", "merge", "--from", String(from), "--into", String(into), "--json"])
        return try JSONDecoder().decode(BenchMergeResult.self, from: data)
    }

    /// Before the Desktop launches a session itself (resume, Start fresh):
    /// a folder still installed for a merged bench gets its own bench's
    /// install first (spec §6.13, D37).
    func ensureInstall(sessionID: Int64) async throws -> SessionEnsureInstallResult {
        let data = try await runner.run(args: ["workbench", "session", "ensure-install", "--session", String(sessionID), "--json"])
        return try JSONDecoder().decode(SessionEnsureInstallResult.self, from: data)
    }
}

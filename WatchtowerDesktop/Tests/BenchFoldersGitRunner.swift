import Foundation
import WatchtowerCore
import WatchtowerTestSupport

/// A stand-in for the Go CLI on a bench of several folders (#2003): each
/// folder is its own repository on its own branch, and `workbench git
/// status` resolves the way Task 4's Go does — `--workbench-folder F`
/// reads F, else the folder holding `--folder`, else home — and reports
/// the folder it used as `workbench_folder_path`. Other verbs answer from
/// `answers` (keyed by `"<verb> <sub>"`, e.g. `"folder add"`), else `{}`.
/// Every argv is recorded.
final class BenchFoldersGitRunner: CLIRunnerProtocol, @unchecked Sendable {
    struct Folder {
        let id: Int64
        let path: String
        var branch: String
    }

    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var folders: [Folder]
    private let homeID: Int64
    private var answers: [String: Result<Data, Error>] = [:]
    /// The CLI predates `--workbench-folder` handling: every status is home's.
    var answersHomeOnly = false
    private let signal = StateSignal()

    init(folders: [Folder], homeID: Int64) {
        self.folders = folders
        self.homeID = homeID
    }

    var invocations: [[String]] { lock.withLock { recorded } }

    /// The `workbench git status` argv recorded, in order.
    var statusReads: [[String]] { invocations.filter { $0.starts(with: ["workbench", "git", "status"]) } }

    func answer(_ verb: String, _ result: Result<Data, Error>) { lock.withLock { answers[verb] = result } }

    func setBranch(_ branch: String, folderID: Int64) {
        lock.withLock {
            if let index = folders.firstIndex(where: { $0.id == folderID }) { folders[index].branch = branch }
        }
    }

    func addFolder(_ folder: Folder) { lock.withLock { folders.append(folder) } }

    /// Returns once `predicate` holds for the recorded argv — the fake's own
    /// signal, no clock.
    func until(_ predicate: @escaping @Sendable ([[String]]) -> Bool) async {
        await signal.until { [self] in predicate(invocations) }
    }

    func run(args: [String]) async throws -> Data {
        let answer: Result<Data, Error> = lock.withLock {
            recorded.append(args)
            if args.starts(with: ["workbench", "git", "status"]) { return .success(statusJSON(args)) }
            let verb = args.dropFirst().prefix(2).joined(separator: " ")
            return answers[verb] ?? .success(Data("{}".utf8))
        }
        signal.changed()
        return try answer.get()
    }

    /// Called under `lock`.
    private func statusJSON(_ args: [String]) -> Data {
        let value = { (flag: String) in args.firstIndex(of: flag).map { args[$0 + 1] } }
        guard var folder = folders.first(where: { $0.id == homeID }) else { return Data("{}".utf8) }
        if !answersHomeOnly {
            if let id = value("--workbench-folder").flatMap(Int64.init), let match = folders.first(where: { $0.id == id }) {
                folder = match
            } else if let path = value("--folder"),
                      let match = folders.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
                folder = match
            }
        }
        let workbench = value("--workbench") ?? "0"
        return Data(#"""
            {"workbench_id":\#(workbench),"git_available":true,"git":true,"branch":"\#(folder.branch)","head":"a1b2c3d",
             "dirty":false,"changes":0,"top_level":"\#(folder.path)","git_dir":"\#(folder.path)/.git",
             "common_dir":"\#(folder.path)/.git","status_ok":true,"status_error":"",
             "workbench_folder_path":"\#(folder.path)"}
            """#.utf8)
    }
}

import Foundation
import Observation
import WatchtowerCore

/// Where each workbench session's agent works (board #565, spec
/// 2026-10-12-session-worktree-design §4): the workbench folder, a linked
/// worktree with its branch, a removed worktree, or not known yet. Owned by
/// `WorkbenchesViewModel` (AppState-owned), so a read started on a page
/// lands after the owner leaves it.
///
/// Places come only from `workbench git status --folder <cwd>` — the Desktop
/// never runs git. The cost stays bounded: a cwd lexically equal to the
/// workbench folder is the main folder with no process; any other cwd is
/// read once and cached by `(workbench, cwd)`, so sessions sharing a cwd share
/// the read and an unchanged cwd is never read again. At most one read per
/// cwd runs, plus one queued rerun. A cwd is re-read only when it changes
/// (the hook stored a new one), on the workbench's refs watcher and on app
/// activation (`refreshPlaces`, the branch of a worktree may have moved) — only for
/// workbenches on screen (`followWorkbench`). A failed read, or an envelope that is no
/// verdict, keeps the last place, marked stale.
@MainActor
@Observable
final class SessionPlaceCenter {
    /// The stored cwds of a workbench's rows (`fetchAgentCwds`, through
    /// `DatabasePool.read` only — see there).
    typealias CwdReader = @Sendable (_ workbenchID: Int64) async throws -> [Int64: SessionAgentCwd]
    /// `workbench git status --workbench <id> --folder <cwd>`.
    typealias StatusReader = (_ workbenchID: Int64, _ folder: String) async throws -> WorkbenchGitStatus

    struct CwdKey: Hashable, Sendable {
        let workbenchID: Int64
        let cwd: String
    }

    /// Each session's place, by session id; absent = unknown.
    private(set) var sessionPlaces: [Int64: SessionPlace] = [:]
    /// Cwds whose last read failed or gave no verdict: their place is the
    /// last one known.
    private(set) var staleCwds: Set<CwdKey> = []

    @ObservationIgnored private let readCwds: CwdReader
    @ObservationIgnored private let readStatus: StatusReader
    @ObservationIgnored private let isLive: (Int64) -> Bool
    /// Workbenches on screen, with their folder.
    @ObservationIgnored private var followed: [Int64: String] = [:]
    /// Each session's trusted cwd (nil = untrusted or none) and workbench.
    @ObservationIgnored private var sessionKeys: [Int64: (workbenchID: Int64, cwd: String?)] = [:]
    /// The resolved place of every cwd in use.
    @ObservationIgnored private var cwdPlaces: [CwdKey: SessionPlace] = [:]
    /// The read running per cwd / per workbench, and whether one more is
    /// asked for after it.
    @ObservationIgnored private var statusReads: [CwdKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var statusQueued: Set<CwdKey> = []
    @ObservationIgnored private var cwdReads: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored private var cwdQueued: Set<Int64> = []

    init(readCwds: @escaping CwdReader, readStatus: @escaping StatusReader, isLive: @escaping (Int64) -> Bool) {
        self.readCwds = readCwds
        self.readStatus = readStatus
        self.isLive = isLive
    }

    /// The session's place; unknown until one is known.
    func currentPlace(sessionID: Int64) -> SessionPlace {
        sessionPlaces[sessionID] ?? .unknown
    }

    /// Whether the session's place is the last one known: its cwd's latest
    /// read failed or gave no verdict.
    func isStale(sessionID: Int64) -> Bool {
        guard let entry = sessionKeys[sessionID], let cwd = entry.cwd else { return false }
        return staleCwds.contains(CwdKey(workbenchID: entry.workbenchID, cwd: cwd))
    }

    /// The workbench's page is on screen: its cwds are read now and kept up
    /// to date by `cwdsMayHaveChanged` and `refreshPlaces`.
    @discardableResult
    func followWorkbench(_ workbenchID: Int64, folder: String) -> Task<Void, Never> {
        followed[workbenchID] = folder
        return rereadCwds(workbenchID: workbenchID)
    }

    /// The page went away: nothing new is started for it. Places, and reads
    /// already running, stay.
    func unfollowWorkbench(_ workbenchID: Int64) {
        followed[workbenchID] = nil
    }

    /// A hook may have stored a new cwd (the session states were read):
    /// every followed workbench's cwds are read again; only a changed cwd
    /// starts a git read.
    @discardableResult
    func cwdsMayHaveChanged() -> Task<Void, Never> {
        let reads = followed.keys.map { rereadCwds(workbenchID: $0) }
        return Task { for read in reads { await read.value } }
    }

    /// The refs watcher fired or the app became active: every cwd in use of
    /// a followed workbench other than the workbench folder itself is read
    /// again (a worktree's branch may have moved, or the worktree gone).
    @discardableResult
    func refreshPlaces(workbenchID: Int64) -> Task<Void, Never> {
        guard let folder = followed[workbenchID] else { return Task {} }
        let keys = keysInUse(workbenchID: workbenchID).filter {
            !SessionPlace.isWorkbenchFolder($0.cwd, workbenchFolder: folder)
        }
        let reads = keys.map { readPlace($0, folder: folder) }
        return Task { for read in reads { await read.value } }
    }

    // MARK: - Private

    /// Coalesced: a call while a read runs asks for one more after it and
    /// gets the running one, which ends after that rerun.
    private func rereadCwds(workbenchID: Int64) -> Task<Void, Never> {
        if let running = cwdReads[workbenchID] {
            cwdQueued.insert(workbenchID)
            return running
        }
        let read = Task {
            repeat {
                self.cwdQueued.remove(workbenchID)
                await self.readCwdsOnce(workbenchID: workbenchID)
            } while self.cwdQueued.contains(workbenchID)
            self.cwdReads[workbenchID] = nil
        }
        cwdReads[workbenchID] = read
        return read
    }

    /// A read started on screen lands even if the page goes away meanwhile.
    private func readCwdsOnce(workbenchID: Int64) async {
        guard let folder = followed[workbenchID] else { return }
        let rows: [Int64: SessionAgentCwd]
        do {
            rows = try await readCwds(workbenchID)
        } catch {
            // The places stay as they are; the next state read tries again.
            print("[SessionPlace] cwds of workbench \(workbenchID) could not be read: \(error.localizedDescription)")
            return
        }
        let changed = assignCwds(rows, workbenchID: workbenchID, folder: folder)
        dropUnusedCwds(workbenchID: workbenchID)
        for read in changed.map({ readPlace($0, folder: folder) }) { await read.value }
    }

    /// Records each session's trusted cwd and returns the cwds that need a
    /// read: new ones not yet placed.
    private func assignCwds(_ rows: [Int64: SessionAgentCwd], workbenchID: Int64, folder: String) -> [CwdKey] {
        let known = sessionKeys.filter { $0.value.workbenchID == workbenchID }.map(\.key)
        var toRead: [CwdKey] = []
        for sessionID in Set(known).union(rows.keys) {
            let cwd = SessionPlace.trustedCwd(row: rows[sessionID], live: isLive(sessionID))
            if let entry = sessionKeys[sessionID], entry.cwd == cwd { continue }
            sessionKeys[sessionID] = (workbenchID, cwd)
            guard let cwd else {
                sessionPlaces[sessionID] = .unknown
                continue
            }
            let key = CwdKey(workbenchID: workbenchID, cwd: cwd)
            if SessionPlace.isWorkbenchFolder(cwd, workbenchFolder: folder) {
                cwdPlaces[key] = .main
            }
            if let place = cwdPlaces[key] {
                sessionPlaces[sessionID] = place
            } else if !toRead.contains(key) {
                // Until it is read, the session keeps its last place.
                toRead.append(key)
            }
        }
        return toRead
    }

    /// A cwd no session of the workbench holds any more leaves the cache.
    private func dropUnusedCwds(workbenchID: Int64) {
        let inUse = keysInUse(workbenchID: workbenchID)
        for key in cwdPlaces.keys where key.workbenchID == workbenchID && !inUse.contains(key) {
            cwdPlaces[key] = nil
            staleCwds.remove(key)
        }
    }

    private func keysInUse(workbenchID: Int64) -> Set<CwdKey> {
        Set(sessionKeys.values.compactMap { entry in
            guard entry.workbenchID == workbenchID, let cwd = entry.cwd else { return nil }
            return CwdKey(workbenchID: workbenchID, cwd: cwd)
        })
    }

    /// One `--folder` read for `key`, coalesced as `rereadCwds`.
    private func readPlace(_ key: CwdKey, folder: String) -> Task<Void, Never> {
        if let running = statusReads[key] {
            statusQueued.insert(key)
            return running
        }
        let read = Task {
            repeat {
                self.statusQueued.remove(key)
                await self.readPlaceOnce(key, folder: folder)
            } while self.statusQueued.contains(key)
            self.statusReads[key] = nil
        }
        statusReads[key] = read
        return read
    }

    private func readPlaceOnce(_ key: CwdKey, folder: String) async {
        let status: WorkbenchGitStatus
        do {
            status = try await readStatus(key.workbenchID, key.cwd)
        } catch {
            print("[SessionPlace] workbench git status --folder for workbench \(key.workbenchID) failed: \(error)")
            staleCwds.insert(key)
            return
        }
        let last = cwdPlaces[key] ?? sessionsHolding(key).lazy.compactMap { self.sessionPlaces[$0] }.first
        guard let place = SessionPlace.resolvePlace(cwd: key.cwd, status: status, workbenchFolder: folder, last: last) else {
            staleCwds.insert(key)
            return
        }
        staleCwds.remove(key)
        // A cwd every session left meanwhile is not cached again.
        let holders = sessionsHolding(key)
        guard !holders.isEmpty else { return }
        cwdPlaces[key] = place
        for sessionID in holders where sessionPlaces[sessionID] != place {
            sessionPlaces[sessionID] = place
        }
    }

    private func sessionsHolding(_ key: CwdKey) -> [Int64] {
        sessionKeys.compactMap { id, entry in
            entry.workbenchID == key.workbenchID && entry.cwd == key.cwd ? id : nil
        }
    }
}

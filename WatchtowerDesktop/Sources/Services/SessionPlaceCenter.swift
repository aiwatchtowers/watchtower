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
/// cwd runs, plus one queued rerun. Cwds are read again when the session
/// states show a change (`stateRowsRead`, `cwdsMayHaveChanged`); a cwd's place
/// is read again on the workbench's refs watcher, on app activation and on
/// coming back to the page (`refreshPlaces`, the branch of a worktree may
/// have moved) — only for workbenches on screen (`followWorkbench`).
///
/// Fail closed: a session whose cwd moved to one not read yet, or whose read
/// failed, is unknown — never its previous place — and reads as stale
/// (`isPlaceStale`). A failed or no-verdict re-read of the same cwd keeps
/// that cwd's last place, marked stale.
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
    /// last one known (or unknown when none).
    private(set) var staleCwds: Set<CwdKey> = []

    @ObservationIgnored private let readCwds: CwdReader
    @ObservationIgnored private let readStatus: StatusReader
    @ObservationIgnored private let isLive: (Int64) -> Bool
    /// Workbenches on screen, with their folder.
    @ObservationIgnored private var followed: [Int64: String] = [:]
    /// Each session's trusted cwd; a session without one is absent.
    @ObservationIgnored private var sessionKeys: [Int64: CwdKey] = [:]
    /// The resolved place of every cwd in use.
    @ObservationIgnored private var cwdPlaces: [CwdKey: SessionPlace] = [:]
    /// The last cwd stamps the session states read showed, by session id.
    @ObservationIgnored private var cwdStamps: [Int64: String] = [:]
    /// The read running per cwd / per workbench, and whether one more is
    /// asked for after it.
    @ObservationIgnored private var statusReads: [CwdKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var statusQueued: Set<CwdKey> = []
    @ObservationIgnored private var cwdReads: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored private var cwdQueued: Set<Int64> = []
    /// Bumped by `forgetWorkbench`: a cwd read that started before lands on
    /// nothing.
    @ObservationIgnored private var forgetCounts: [Int64: Int] = [:]

    init(readCwds: @escaping CwdReader, readStatus: @escaping StatusReader, isLive: @escaping (Int64) -> Bool) {
        self.readCwds = readCwds
        self.readStatus = readStatus
        self.isLive = isLive
    }

    /// The session's place; unknown until one is known.
    func currentPlace(sessionID: Int64) -> SessionPlace {
        sessionPlaces[sessionID] ?? .unknown
    }

    /// Whether the session's place is unproven: its cwd has not been read
    /// yet (a read pending), or its latest read failed or gave no verdict.
    func isPlaceStale(sessionID: Int64) -> Bool {
        guard let key = sessionKeys[sessionID] else { return false }
        return cwdPlaces[key] == nil || staleCwds.contains(key)
    }

    /// Whether the session's place is proven: its trusted cwd was read and
    /// the latest read of it gave a verdict.
    func isPlaceProven(sessionID: Int64) -> Bool {
        guard let key = sessionKeys[sessionID] else { return false }
        return cwdPlaces[key] != nil && !staleCwds.contains(key)
    }

    /// Reads the workbench's cwds (and a stale place of the session) again
    /// until the session's place is proven or `timeout` passes — a session
    /// just resumed has none until its hook reports the new run's cwd.
    /// `folder` stands in for a workbench not on screen. True when proven.
    func awaitProvenPlace(sessionID: Int64, workbenchID: Int64, folder: String, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !isPlaceProven(sessionID: sessionID) {
            guard ContinuousClock.now < deadline, !Task.isCancelled else { return false }
            await rereadCwds(workbenchID: workbenchID, fallbackFolder: folder).value
            if let key = sessionKeys[sessionID], staleCwds.contains(key) {
                await readPlace(key, folder: followed[workbenchID] ?? folder).value
            }
            if isPlaceProven(sessionID: sessionID) { break }
            try? await Task.sleep(for: Self.placeRetryInterval)
        }
        return true
    }

    private static let placeRetryInterval: Duration = .milliseconds(200)

    /// The workbench's page is on screen: its cwds are read now and kept up
    /// to date by `cwdsMayHaveChanged` and `refreshPlaces`. Coming back to it,
    /// the places already known are read again too — their branch may have
    /// moved while nothing watched. That runs after the cwds are read again,
    /// on the known cwds still held only (a new cwd was just read).
    @discardableResult
    func followWorkbench(_ workbenchID: Int64, folder: String) -> Task<Void, Never> {
        let returning = followed[workbenchID] == nil
        followed[workbenchID] = folder
        let known = keysInUse(workbenchID: workbenchID)
        let cwds = rereadCwds(workbenchID: workbenchID)
        guard returning, !known.isEmpty else { return cwds }
        return Task {
            await cwds.value
            await self.refreshPlaces(workbenchID: workbenchID, among: known).value
        }
    }

    /// The page went away: nothing new is started for it. Places, and reads
    /// already running, stay.
    func unfollowWorkbench(_ workbenchID: Int64) {
        followed[workbenchID] = nil
    }

    /// The workbench was deleted: everything known about it goes.
    func forgetWorkbench(_ workbenchID: Int64) {
        followed[workbenchID] = nil
        forgetCounts[workbenchID, default: 0] += 1
        for (sessionID, key) in sessionKeys where key.workbenchID == workbenchID {
            evictSession(sessionID)
        }
        dropUnusedCwds(workbenchID: workbenchID)
    }

    /// A session started, stopped or began a new run (the states changed):
    /// whether its stored cwd is trusted may have moved. Every followed
    /// workbench's cwds are read again; only a changed cwd starts a git read.
    @discardableResult
    func cwdsMayHaveChanged() -> Task<Void, Never> {
        let reads = followed.keys.map { rereadCwds(workbenchID: $0) }
        return Task { for read in reads { await read.value } }
    }

    /// The session states were read: the cwds are read again only when a
    /// hook stored a new one (a cwd stamp changed) — no extra read per poll.
    @discardableResult
    func stateRowsRead(_ rows: [SessionAgentStateRow]) -> Task<Void, Never> {
        var stamps: [Int64: String] = [:]
        for row in rows {
            if let stamp = row.agentCwdAt { stamps[row.id] = stamp }
        }
        guard stamps != cwdStamps else { return Task {} }
        cwdStamps = stamps
        return cwdsMayHaveChanged()
    }

    /// The refs watcher fired or the app became active: every cwd in use of
    /// a followed workbench other than the workbench folder itself is read
    /// again (a worktree's branch may have moved, or the worktree gone).
    @discardableResult
    func refreshPlaces(workbenchID: Int64) -> Task<Void, Never> {
        refreshPlaces(workbenchID: workbenchID, among: nil)
    }

    // MARK: - Private

    /// `among`: only these cwds (those still in use); nil = every cwd in use.
    private func refreshPlaces(workbenchID: Int64, among: Set<CwdKey>?) -> Task<Void, Never> {
        guard let folder = followed[workbenchID] else { return Task {} }
        let inUse = keysInUse(workbenchID: workbenchID)
        let keys = (among.map { $0.intersection(inUse) } ?? inUse).filter {
            !SessionPlace.isWorkbenchFolder($0.cwd, workbenchFolder: folder)
        }
        let reads = keys.map { readPlace($0, folder: folder) }
        return Task { for read in reads { await read.value } }
    }

    /// Coalesced: a call while a read runs asks for one more after it and
    /// gets the running one, which ends after that rerun.
    /// `fallbackFolder`: the workbench folder when it is not followed.
    private func rereadCwds(workbenchID: Int64, fallbackFolder: String? = nil) -> Task<Void, Never> {
        if let running = cwdReads[workbenchID] {
            cwdQueued.insert(workbenchID)
            return running
        }
        let read = Task {
            repeat {
                self.cwdQueued.remove(workbenchID)
                await self.readCwdsOnce(workbenchID: workbenchID, fallbackFolder: fallbackFolder)
            } while self.cwdQueued.contains(workbenchID)
            self.cwdReads[workbenchID] = nil
        }
        cwdReads[workbenchID] = read
        return read
    }

    /// A read started on screen lands even if the page goes away meanwhile,
    /// but not when the workbench was deleted meanwhile.
    private func readCwdsOnce(workbenchID: Int64, fallbackFolder: String?) async {
        guard let folder = followed[workbenchID] ?? fallbackFolder else { return }
        let forgets = forgetCounts[workbenchID, default: 0]
        let rows: [Int64: SessionAgentCwd]
        do {
            rows = try await readCwds(workbenchID)
        } catch {
            // The places stay as they are; the next state read tries again.
            print("[SessionPlace] cwds of workbench \(workbenchID) could not be read: \(error.localizedDescription)")
            return
        }
        guard forgetCounts[workbenchID, default: 0] == forgets else { return }
        let changed = assignCwds(rows, workbenchID: workbenchID, folder: folder)
        dropUnusedCwds(workbenchID: workbenchID)
        for read in changed.map({ readPlace($0, folder: folder) }) { await read.value }
    }

    /// Records each session's trusted cwd and returns the cwds that need a
    /// read: new ones not yet placed. A session without a trusted cwd (or
    /// deleted) is dropped: unknown.
    private func assignCwds(_ rows: [Int64: SessionAgentCwd], workbenchID: Int64, folder: String) -> [CwdKey] {
        let known = sessionKeys.filter { $0.value.workbenchID == workbenchID }.map(\.key)
        var toRead: [CwdKey] = []
        for sessionID in Set(known).union(rows.keys) {
            guard let cwd = SessionPlace.trustedCwd(row: rows[sessionID], live: isLive(sessionID)) else {
                evictSession(sessionID)
                continue
            }
            let key = CwdKey(workbenchID: workbenchID, cwd: cwd)
            guard sessionKeys[sessionID] != key else { continue }
            sessionKeys[sessionID] = key
            if SessionPlace.isWorkbenchFolder(cwd, workbenchFolder: folder) {
                cwdPlaces[key] = .main
            }
            // Until a new cwd is read the session is unknown, never its
            // previous place (fail closed).
            setPlace(cwdPlaces[key], sessionID: sessionID)
            if cwdPlaces[key] == nil, !toRead.contains(key) {
                toRead.append(key)
            }
        }
        return toRead
    }

    private func evictSession(_ sessionID: Int64) {
        sessionKeys[sessionID] = nil
        setPlace(nil, sessionID: sessionID)
    }

    /// Assigns only on a change, so an unchanged place re-renders nothing.
    private func setPlace(_ place: SessionPlace?, sessionID: Int64) {
        guard sessionPlaces[sessionID] != place else { return }
        sessionPlaces[sessionID] = place
    }

    /// Changes `staleCwds` only when the membership changes.
    private func setStale(_ key: CwdKey, _ stale: Bool) {
        guard staleCwds.contains(key) != stale else { return }
        if stale {
            staleCwds.insert(key)
        } else {
            staleCwds.remove(key)
        }
    }

    /// A cwd no session of the workbench holds any more leaves the cache and
    /// the stale set.
    private func dropUnusedCwds(workbenchID: Int64) {
        let inUse = keysInUse(workbenchID: workbenchID)
        for key in cwdPlaces.keys where key.workbenchID == workbenchID && !inUse.contains(key) {
            cwdPlaces[key] = nil
        }
        let unusedStale = staleCwds.filter { $0.workbenchID == workbenchID && !inUse.contains($0) }
        if !unusedStale.isEmpty { staleCwds.subtract(unusedStale) }
    }

    private func keysInUse(workbenchID: Int64) -> Set<CwdKey> {
        Set(sessionKeys.values.filter { $0.workbenchID == workbenchID })
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

    /// Lands only on the sessions holding `key` when it ends: a session
    /// that moved meanwhile keeps its new cwd's place.
    private func readPlaceOnce(_ key: CwdKey, folder: String) async {
        let place = await resolvedPlace(key, folder: folder)
        let holders = sessionsHolding(key)
        // A cwd every session left meanwhile is not cached again.
        guard !holders.isEmpty else {
            setStale(key, false)
            return
        }
        guard let place else {
            setStale(key, true)
            return
        }
        setStale(key, false)
        cwdPlaces[key] = place
        for sessionID in holders { setPlace(place, sessionID: sessionID) }
    }

    /// nil = the read failed or gave no verdict.
    private func resolvedPlace(_ key: CwdKey, folder: String) async -> SessionPlace? {
        do {
            let status = try await readStatus(key.workbenchID, key.cwd)
            return SessionPlace.resolvePlace(cwd: key.cwd, status: status, workbenchFolder: folder, last: cwdPlaces[key])
        } catch {
            print("[SessionPlace] workbench git status --folder for workbench \(key.workbenchID) failed: \(error)")
            return nil
        }
    }

    private func sessionsHolding(_ key: CwdKey) -> [Int64] {
        sessionKeys.compactMap { id, held in held == key ? id : nil }
    }
}

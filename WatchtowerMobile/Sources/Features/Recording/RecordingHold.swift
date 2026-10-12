import Foundation
import WatchtowerSync

/// A recording a wipe took out of the replica, waiting for the hub it was
/// recorded for (board #63). Its audio sits in the hold folder until an
/// environment of that hub adopts it.
struct HeldRecording: Codable, Equatable, Identifiable, Sendable {
    let id: String
    /// The audio file's name (in the hold folder, or back in the
    /// recordings folder after a crash mid-move).
    let fileName: String
    /// The hub the recording goes to: only an environment of this hub
    /// adopts it, so it never reaches another owner's Mac.
    let hubID: String
    /// The Mac's name as its heartbeat last gave it; nil when unknown.
    let macName: String?
    let startedAt: Date
    let endedAt: Date
    let durationSec: Int
    let titleHint: String?
    let eventID: String?
    let marks: [Int]

    init(_ row: PhoneRecording, marks: [Int], hubID: String, macName: String?) {
        id = row.id
        fileName = URL(fileURLWithPath: row.storedPath).lastPathComponent
        self.hubID = hubID
        self.macName = macName
        startedAt = row.startedAt
        endedAt = row.endedAt
        durationSec = row.durationSec
        titleHint = row.titleHint
        eventID = row.eventID
        self.marks = marks
    }
}

/// The hold: recordings carried across a wipe, kept outside the replica in
/// the recordings folder's hidden `.held` folder with a JSON manifest. A
/// hidden folder is out of the launch sweep's reach (it skips hidden
/// files), so held audio survives every boot, a failed restart and a kill,
/// until its hub's environment adopts it (`AppEnvironment.adoptHeld`).
/// Files that could not be classified (the ledger was unreadable) go to
/// `.held/unreadable`: kept, never sent.
struct RecordingHold {
    let directory: URL

    init(recordingsDirectory: URL) {
        directory = recordingsDirectory.appendingPathComponent(".held", isDirectory: true)
    }

    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }
    private var recordingsDirectory: URL { directory.deletingLastPathComponent() }

    /// Every held recording; empty when nothing is held.
    func load() throws -> [HeldRecording] {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return [] }
        let decoder = JSONDecoder()
        return try decoder.decode([HeldRecording].self, from: Data(contentsOf: manifestURL))
    }

    private func save(_ held: [HeldRecording]) throws {
        if held.isEmpty {
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                try FileManager.default.removeItem(at: manifestURL)
            }
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(held).write(to: manifestURL, options: .atomic)
    }

    /// Adds `recordings` (an entry with a held id is replaced): the
    /// manifest is written first, then each file moves in, so a crash in
    /// between leaves a listed file in the recordings folder, which
    /// `audioURL` still finds.
    func hold(_ recordings: [HeldRecording]) throws {
        guard !recordings.isEmpty else { return }
        let ids = Set(recordings.map(\.id))
        try save(try load().filter { !ids.contains($0.id) } + recordings)
        for recording in recordings {
            let source = recordingsDirectory.appendingPathComponent(recording.fileName)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try FileManager.default.moveItem(at: source, to: directory.appendingPathComponent(recording.fileName))
        }
    }

    /// Where a held recording's audio is now; nil when it is gone.
    func audioURL(of recording: HeldRecording) -> URL? {
        [directory, recordingsDirectory]
            .map { $0.appendingPathComponent(recording.fileName) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Moves a held recording's audio back into the recordings folder and
    /// returns it there; nil when the audio is gone.
    func restoreAudio(of recording: HeldRecording) throws -> URL? {
        guard let current = audioURL(of: recording) else { return nil }
        let target = recordingsDirectory.appendingPathComponent(recording.fileName)
        if current != target {
            try FileManager.default.moveItem(at: current, to: target)
        }
        return target
    }

    /// Drops entries from the manifest (their audio is handled by the
    /// caller).
    func remove(ids: Set<String>) throws {
        guard !ids.isEmpty else { return }
        try save(try load().filter { !ids.contains($0.id) })
    }

    /// Deletes every held recording and its audio (an iCloud account
    /// change: the recordings were made for the old account's Macs).
    /// Returns how many there were.
    @discardableResult
    func dropAll() throws -> Int {
        let held = try load()
        for recording in held {
            if let url = audioURL(of: recording) {
                try FileManager.default.removeItem(at: url)
            }
        }
        try save([])
        return held.count
    }

    /// The ledger could not be read: every audio file still in the
    /// recordings folder moves to `.held/unreadable`, out of the sweep's
    /// reach. A name already taken there gets a numbered one; a file that
    /// cannot move does not stop the others. Returns how many moved and the
    /// failures.
    @discardableResult
    func protectUnreadable() throws -> (moved: Int, failures: [String]) {
        let unreadable = directory.appendingPathComponent("unreadable", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        guard !files.isEmpty else { return (0, []) }
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        var moved = 0
        var failures: [String] = []
        for file in files {
            do {
                try FileManager.default.moveItem(at: file, to: Self.freeName(for: file.lastPathComponent, in: unreadable))
                moved += 1
            } catch {
                failures.append("\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (moved, failures)
    }

    /// `name` in `folder`, or `<stem>-2.<ext>`, `<stem>-3.<ext>`, … when
    /// it is taken.
    static func freeName(for name: String, in folder: URL) -> URL {
        let candidate = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        while true {
            let numbered = folder.appendingPathComponent(ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)")
            if !FileManager.default.fileExists(atPath: numbered.path) { return numbered }
            index += 1
        }
    }
}

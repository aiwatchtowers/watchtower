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

/// An audio file in `.held/unreadable` (`RecordingHold.protectUnreadable`):
/// its ledger could not be read, so it is never sent; Recordings lists it
/// for the owner to share or delete (board #171). The uploader's sealed
/// copies moved there with it are never listed.
struct UnreadableAudio: Equatable, Identifiable, Sendable {
    let url: URL
    let byteCount: Int?
    let modifiedAt: Date?

    var id: String { url.lastPathComponent }
    var name: String { url.lastPathComponent }
}

/// The hold: recordings carried across a wipe, kept outside the replica in
/// a hidden `.held` folder with a JSON manifest, shared by every hub
/// (`HubPaths.holdDirectory`). A hidden folder is out of the launch sweep's
/// reach (it skips hidden files), so held audio survives every boot, a
/// failed restart and a kill, until its hub's session adopts it
/// (`HubSession.adoptHeld`). Each move in or out names the hub's own
/// recordings folder (`recordingsDirectory`). Files that could not be
/// classified (the ledger was unreadable) go to `.held/unreadable`: kept,
/// never sent.
///
/// File protection (mobile E2E D8): the folders and the manifest are class C
/// (`completeUntilFirstUserAuthentication`), so a wipe or a boot while the
/// phone is locked (an iCloud account change, a push launch) still reads and
/// writes the manifest and hands the audio over; the manifest holds metadata
/// only (titles, times, the Mac's name). Moved audio keeps its own class
/// (`completeUnlessOpen` for a capture). Should an adoption still fail, it
/// runs again after unlock (`HubSession.keysBecameAvailable`).
struct RecordingHold {
    /// The `.held` folder itself.
    let directory: URL
    /// A hub's own recordings folder (`HubPaths.recordingsDirectory`),
    /// where a crash mid-move leaves a held recording's audio; nil when
    /// unknown (the demo, tests), then only the hold is looked in.
    let hubRecordingsDirectory: (@Sendable (String) -> URL)?

    init(directory: URL, hubRecordingsDirectory: (@Sendable (String) -> URL)? = nil) {
        self.directory = directory
        self.hubRecordingsDirectory = hubRecordingsDirectory
    }

    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

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
        try FileProtection.protectDirectory(directory)
        try FileProtection.write(try JSONEncoder().encode(held), to: manifestURL, as: FileProtection.ciphertext)
    }

    /// Adds `recordings` (an entry with a held id is replaced), moving
    /// their audio in from `recordingsDirectory`: the manifest is written
    /// first, then each file moves in, so a crash in between leaves a
    /// listed file in the recordings folder, which `audioURL` still finds.
    func hold(_ recordings: [HeldRecording], from recordingsDirectory: URL) throws {
        guard !recordings.isEmpty else { return }
        let ids = Set(recordings.map(\.id))
        try save(try load().filter { !ids.contains($0.id) } + recordings)
        for recording in recordings {
            let source = recordingsDirectory.appendingPathComponent(recording.fileName)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try FileManager.default.moveItem(at: source, to: directory.appendingPathComponent(recording.fileName))
        }
    }

    /// Where a held recording's audio is now (the hold, or
    /// `recordingsDirectory` after a crash mid-move); nil when it is gone.
    func audioURL(of recording: HeldRecording, recordingsDirectory: URL) -> URL? {
        [directory, recordingsDirectory]
            .map { $0.appendingPathComponent(recording.fileName) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Where a held recording's audio is now: the hold, or its hub's own
    /// recordings folder after a crash mid-move; nil when it is gone.
    func audioURL(of recording: HeldRecording) -> URL? {
        guard let hubFolder = hubRecordingsDirectory?(recording.hubID) else {
            let url = directory.appendingPathComponent(recording.fileName)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        return audioURL(of: recording, recordingsDirectory: hubFolder)
    }

    /// Moves a held recording's audio back into `recordingsDirectory` and
    /// returns it there; nil when the audio is gone.
    func restoreAudio(of recording: HeldRecording, to recordingsDirectory: URL) throws -> URL? {
        guard let current = audioURL(of: recording, recordingsDirectory: recordingsDirectory) else { return nil }
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

    /// Deletes a held recording the owner gave up on (its Mac is no longer
    /// linked, board #171): its audio first, wherever `audioURL(of:)`
    /// finds it (the hold, or its hub's folder after a crash mid-move),
    /// then its manifest entry, so a failed delete leaves it listed.
    func discard(id: String) throws {
        guard let recording = try load().first(where: { $0.id == id }) else { return }
        if let audio = audioURL(of: recording) {
            try FileManager.default.removeItem(at: audio)
        }
        try remove(ids: [id])
    }

    private var unreadableDirectory: URL { directory.appendingPathComponent("unreadable", isDirectory: true) }

    /// The uploader's sealed copy of a recording (`<id>.enc`,
    /// `<id>-<n>.enc`): named by the ledger row, so with the ledger
    /// unreadable it cannot be matched to its audio.
    private static func isSealed(_ url: URL) -> Bool { url.pathExtension == "enc" }

    private func unreadableFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: unreadableDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: unreadableDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
    }

    /// The audio in `.held/unreadable`, by name; empty when there is none.
    /// Sealed copies are not audio the owner can play: never listed, so a
    /// folder holding only those shows no row.
    func unreadableAudio() throws -> [UnreadableAudio] {
        try unreadableFiles()
            .filter { !Self.isSealed($0) }
            .map { url in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return UnreadableAudio(url: url, byteCount: values?.fileSize, modifiedAt: values?.contentModificationDate)
            }
            .sorted { $0.name < $1.name }
    }

    /// Deletes audio files from `.held/unreadable` by name; a name that is
    /// not a plain audio file name there deletes nothing, and the first
    /// failure stops the rest. Once no audio is left, the sealed copies
    /// go too: they belong to the deleted audio, and which to which cannot
    /// be told (`isSealed`).
    func deleteUnreadable(named names: [String]) throws {
        for name in names {
            guard !name.isEmpty, !name.hasPrefix("."), URL(fileURLWithPath: name).lastPathComponent == name else { continue }
            let file = unreadableDirectory.appendingPathComponent(name)
            guard !Self.isSealed(file), FileManager.default.fileExists(atPath: file.path) else { continue }
            try FileManager.default.removeItem(at: file)
        }
        let left = try unreadableFiles()
        guard !left.contains(where: { !Self.isSealed($0) }) else { return }
        for sealed in left {
            try FileManager.default.removeItem(at: sealed)
        }
    }

    /// Deletes every held recording and its audio (an iCloud account
    /// change: the recordings were made for the old account's Macs); audio
    /// a crash left mid-move is looked for in `recordingsDirectory`.
    /// Returns how many there were.
    @discardableResult
    func dropAll(recordingsDirectory: URL) throws -> Int {
        let held = try load()
        for recording in held {
            if let url = audioURL(of: recording, recordingsDirectory: recordingsDirectory) {
                try FileManager.default.removeItem(at: url)
            }
        }
        try save([])
        return held.count
    }

    /// The ledger could not be read: every audio file still in
    /// `recordingsDirectory` moves to `.held/unreadable`, out of the sweep's
    /// reach. A name already taken there gets a numbered one; a file that
    /// cannot move does not stop the others. Returns how many moved and the
    /// failures.
    @discardableResult
    func protectUnreadable(in recordingsDirectory: URL) throws -> (moved: Int, failures: [String]) {
        let unreadable = unreadableDirectory
        let files = try FileManager.default.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        guard !files.isEmpty else { return (0, []) }
        try FileProtection.protectDirectory(unreadable)
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

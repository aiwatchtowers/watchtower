import Foundation
import os

/// Moves the recording sidecars older versions wrote next to the audio into
/// `pending_transcripts` rows (#604 S3/S4), then deletes them. Older versions
/// kept a recording pending exactly while its `rec_X.meta` existed (event link
/// and title; `rec_X.txt` + `rec_X.json` held a transcript kept for a save
/// retry), so:
/// - a stem with a `.meta` becomes a pending row, with its kept transcript;
/// - a stem without one (a lone `.txt` or `.json`, or the pair) was dismissed
///   or saved on the old build: it becomes a dismissed tombstone, and its text
///   is not imported — the files are just deleted (the audio stays).
///
/// A stem with an unreadable sidecar keeps all its files (logged by file
/// name); the next launch tries again. A stem counts as imported only once
/// its `.meta` is gone; a delete that fails is logged per file and retried at
/// the next launch (the row writes are idempotent).
package enum LegacyRecordingSidecarImport {
    private struct Meta: Decodable {
        let eventID: String?
        let title: String?
    }

    private static let log = Logger(subsystem: "com.watchtower.desktop", category: "recording-import")

    /// Imports every `rec_*` sidecar stem in `dir`. Returns how many stems
    /// were fully moved (rows written, sidecars deleted).
    @discardableResult
    package static func importAll(in dir: URL, into store: PendingTranscriptStore) async -> Int {
        let fm = FileManager.default
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: dir.path)
        } catch CocoaError.fileReadNoSuchFile {
            return 0
        } catch {
            log.error("cannot list the recordings folder: \(error.localizedDescription, privacy: .public)")
            return 0
        }
        let sidecarExtensions: Set<String> = ["meta", "txt", "json"]
        var stems: [String: Set<String>] = [:]
        for name in names where name.hasPrefix("rec_") {
            let ext = (name as NSString).pathExtension
            guard sidecarExtensions.contains(ext) else { continue }
            stems[(name as NSString).deletingPathExtension, default: []].insert(ext)
        }
        var imported = 0
        for (stem, exts) in stems.sorted(by: { $0.key < $1.key }) where await importStem(stem, exts, in: dir, into: store) {
            imported += 1
        }
        return imported
    }

    private static func importStem(
        _ stem: String,
        _ exts: Set<String>,
        in dir: URL,
        into store: PendingTranscriptStore
    ) async -> Bool {
        let fm = FileManager.default
        let file = { (ext: String) in dir.appendingPathComponent("\(stem).\(ext)") }
        let audioName = ["caf", "m4a"].map { "\(stem).\($0)" }
            .first { fm.fileExists(atPath: dir.appendingPathComponent($0).path) } ?? "\(stem).caf"
        let started = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(audioName).path))?[.modificationDate]
            as? Date ?? Date()
        guard exts.contains("meta") else {
            // Dismissed or saved on the old build: never pending again.
            do {
                try await store.dismiss(recording: audioName, at: started)
            } catch {
                log.error("""
                    keeping the sidecars of \(stem, privacy: .public): \(error.localizedDescription, privacy: .public)
                    """)
                return false
            }
            return delete(exts.sorted(), of: stem, in: dir)
        }
        guard let data = try? Data(contentsOf: file("meta")),
              let meta = try? JSONDecoder().decode(Meta.self, from: data) else {
            return keep(file("meta"))
        }
        var transcript: (text: String, metaJSON: String)?
        if exts.contains("txt"), exts.contains("json") {
            guard let text = try? String(contentsOf: file("txt"), encoding: .utf8) else { return keep(file("txt")) }
            guard let json = try? String(contentsOf: file("json"), encoding: .utf8),
                  (try? JSONSerialization.jsonObject(with: Data(json.utf8))) is [String: Any] else {
                return keep(file("json"))
            }
            transcript = (text, json)
        }
        do {
            // An older build recorded no private choice: private until the
            // owner opens the recovered pill's lock (MEETPRIV fails closed).
            try await store.begin(recording: audioName, eventID: meta.eventID, title: meta.title,
                                  isPrivate: true, at: started)
            if let transcript {
                try await store.saveTranscript(recording: audioName, text: transcript.text, metaJSON: transcript.metaJSON,
                                               at: started)
            }
        } catch {
            log.error("keeping the sidecars of \(stem, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
        // The `.meta` goes last: while it stands, the next launch imports
        // the stem again.
        return delete(exts.subtracting(["meta"]).sorted() + ["meta"], of: stem, in: dir)
    }

    /// Deletes the stem's sidecars in order; true once every one is gone.
    private static func delete(_ exts: [String], of stem: String, in dir: URL) -> Bool {
        var allGone = true
        for ext in exts {
            let url = dir.appendingPathComponent("\(stem).\(ext)")
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch {
                allGone = false
                log.error("""
                    could not delete \(url.lastPathComponent, privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """)
            }
        }
        return allGone
    }

    private static func keep(_ url: URL) -> Bool {
        log.error("\(url.lastPathComponent, privacy: .public) is unreadable; its sidecars are kept")
        return false
    }
}

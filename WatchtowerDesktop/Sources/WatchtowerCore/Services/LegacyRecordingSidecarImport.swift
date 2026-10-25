import Foundation

/// Moves the recording sidecars older versions wrote next to the audio
/// (`rec_X.meta` — event link and title — and `rec_X.txt` + `rec_X.json` — the
/// transcript kept for a save retry) into `pending_transcripts` rows (#604
/// S3/S4), then deletes them. A stem with an unreadable sidecar keeps all its
/// files and is logged by file name; the next launch tries again.
package enum LegacyRecordingSidecarImport {
    private struct Meta: Decodable {
        let eventID: String?
        let title: String?
    }

    /// Imports every `rec_*` sidecar stem in `dir`. Returns how many stems
    /// became rows.
    @discardableResult
    package static func importAll(in dir: URL, into store: PendingTranscriptStore) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return 0 }
        let sidecarExtensions: Set<String> = ["meta", "txt", "json"]
        var stems: [String: Set<String>] = [:]
        for name in names where name.hasPrefix("rec_") {
            let ext = (name as NSString).pathExtension
            guard sidecarExtensions.contains(ext) else { continue }
            stems[(name as NSString).deletingPathExtension, default: []].insert(ext)
        }
        var imported = 0
        for (stem, exts) in stems.sorted(by: { $0.key < $1.key }) where importStem(stem, exts, in: dir, into: store) {
            imported += 1
        }
        return imported
    }

    private static func importStem(
        _ stem: String,
        _ exts: Set<String>,
        in dir: URL,
        into store: PendingTranscriptStore
    ) -> Bool {
        let fm = FileManager.default
        let file = { (ext: String) in dir.appendingPathComponent("\(stem).\(ext)") }
        let audioName = ["caf", "m4a"].map { "\(stem).\($0)" }
            .first { fm.fileExists(atPath: dir.appendingPathComponent($0).path) } ?? "\(stem).caf"
        var meta: Meta?
        if exts.contains("meta") {
            guard let data = try? Data(contentsOf: file("meta")),
                  let decoded = try? JSONDecoder().decode(Meta.self, from: data) else {
                return keep(file("meta"))
            }
            meta = decoded
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
        let started = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(audioName).path))?[.modificationDate]
            as? Date ?? Date()
        do {
            if meta != nil || transcript == nil {
                try store.begin(recording: audioName, eventID: meta?.eventID, title: meta?.title, at: started)
            }
            if let transcript {
                try store.saveTranscript(recording: audioName, text: transcript.text, metaJSON: transcript.metaJSON,
                                         at: started)
            }
        } catch {
            print("[LegacyRecordingSidecarImport] keeping the sidecars of \(stem): \(error.localizedDescription)")
            return false
        }
        for ext in exts { try? fm.removeItem(at: file(ext)) }
        return true
    }

    private static func keep(_ url: URL) -> Bool {
        print("[LegacyRecordingSidecarImport] \(url.lastPathComponent) is unreadable; its sidecars are kept")
        return false
    }
}

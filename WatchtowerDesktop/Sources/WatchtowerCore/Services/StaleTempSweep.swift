import Foundation

/// Removes the temp files older Desktop versions wrote to hand text to the
/// CLI (#604 S6/S7: it now goes on stdin) when a killed run left them
/// behind: pasted text, transcripts, segments, speaker embeddings, dictation
/// and recipe drafts. Run once at launch, off the main actor; best effort.
package enum StaleTempSweep {
    package static let prefixes = [
        "watchtower-text-", "watchtower-transcript-", "watchtower-segments-", "watchtower-speakers-",
        "dictation-", "watchtower-automation-"
    ]

    /// Removes every entry of `dir` (files and the recipe draft directories)
    /// whose name starts with one of `prefixes` and that was last modified
    /// at least `olderThan` seconds before `now`. Returns how many it removed.
    @discardableResult
    package static func run(in dir: URL, olderThan: TimeInterval = 600, now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var removed = 0
        for name in names where prefixes.contains(where: { name.hasPrefix($0) }) {
            let url = dir.appendingPathComponent(name)
            guard let attributes = try? fm.attributesOfItem(atPath: url.path),
                  let modified = attributes[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) >= olderThan else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }
}

import Foundation

/// Whether Watchtower downloads the meeting transcription model on its own,
/// ahead of any recording (#744). Pure: `AppState` gathers the inputs and
/// acts on the verdict. A recording or a dictation never asks this — first
/// use always downloads what it needs, with the same progress.
package enum TranscriptionModelAutoDownload {
    /// How long the download waits for the very first sync before it starts
    /// anyway: a daemon that never finishes a sync must not leave a Meetings
    /// owner without a model until their first recording.
    package static let firstSyncMaxWait: TimeInterval = 10 * 60

    package enum Decision: Equatable {
        case download
        /// Ask again shortly: no sync has finished yet, and the model's
        /// gigabyte should not compete with it for the network.
        case waitForFirstSync
        case skip
    }

    /// Only the Meetings goal downloads ahead of use — it is the goal that
    /// records. Without it the model waits for the first recording or
    /// dictation. `waited` is how long this verdict has been
    /// `.waitForFirstSync` in a row.
    package static func decide(
        goals: Set<OnboardingGoal>,
        onboardingComplete: Bool,
        modelOnDisk: Bool,
        firstSyncFinished: Bool,
        waited: TimeInterval
    ) -> Decision {
        guard onboardingComplete, goals.contains(.meetings), !modelOnDisk else { return .skip }
        if !firstSyncFinished, waited < firstSyncMaxWait { return .waitForFirstSync }
        return .download
    }
}

/// What a model download shows the owner: the model, its size, the percent,
/// the time left, and why it failed.
package enum ModelDownloadText {
    package static let oneTimeNote = "One-time download — the model stays on this Mac."

    /// "Downloading Large v3 Turbo — 42% of about 1.6 GB, about 3 min left".
    /// The size is the provider's estimate, hence "about"; nil leaves it out.
    package static func progressLine(
        model: String,
        sizeBytes: Int64?,
        fraction: Double,
        secondsLeft: TimeInterval?
    ) -> String {
        let percent = Int((min(max(fraction, 0), 1) * 100).rounded(.down))
        var line = "Downloading \(model) — \(percent)%"
        if let sizeBytes {
            line += " of about \(size(sizeBytes))"
        }
        if let secondsLeft {
            line += ", \(timeLeft(secondsLeft))"
        }
        return line
    }

    package static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    package static func timeLeft(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "less than a minute left" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 90 { return "about \(minutes) min left" }
        return "about \(Int((seconds / 3600).rounded())) h left"
    }

    /// Time left from the progress made since the first report. nil until
    /// there is enough to go on (at least `minElapsed` seconds and one
    /// percent of progress), so the line never flashes a wild guess. A
    /// resumed download starts from its resumed fraction, not from zero.
    package static func secondsLeft(
        startFraction: Double,
        startedAt: Date,
        fraction: Double,
        now: Date,
        minElapsed: TimeInterval = 3
    ) -> TimeInterval? {
        let elapsed = now.timeIntervalSince(startedAt)
        let done = fraction - startFraction
        guard elapsed >= minElapsed, done >= 0.01, fraction < 1 else { return nil }
        return (1 - fraction) / (done / elapsed)
    }

    /// The failure line: a lost connection and a full disk in plain words,
    /// anything else with the underlying error's own text.
    package static func failureMessage(for error: Error, sizeBytes: Int64?) -> String {
        if isOutOfSpace(error) {
            let need = sizeBytes.map { " (about \(size($0)))" } ?? ""
            return "Not enough disk space for the model\(need). Free some space, then retry."
        }
        if isNetworkFailure(error) {
            return "The connection dropped. Retry continues the download from where it stopped."
        }
        return "Couldn't download the model: \(error.localizedDescription)"
    }

    private static let networkCodes: Set<Int> = [
        NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
        NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
        NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed, NSURLErrorSecureConnectionFailed
    ]

    /// A URL-loading failure anywhere in the error: the error itself, an
    /// `NSUnderlyingErrorKey` chain, or a value a library wrapped it in (the
    /// model hub's `networkError(URLError)` case), plus the hub's offline
    /// mode, which it reports only as text.
    package static func isNetworkFailure(_ error: Error) -> Bool {
        if containsError(error, matching: { $0.domain == NSURLErrorDomain && networkCodes.contains($0.code) }) {
            return true
        }
        return String(describing: error).localizedCaseInsensitiveContains("offline")
    }

    private static func isOutOfSpace(_ error: Error) -> Bool {
        containsError(error) {
            ($0.domain == NSCocoaErrorDomain && $0.code == NSFileWriteOutOfSpaceError)
                || ($0.domain == NSPOSIXErrorDomain && $0.code == Int(ENOSPC))
        }
    }

    /// Walks the error, its underlying-error chain and the values it wraps
    /// (an enum case's payload), a few levels deep.
    private static func containsError(
        _ error: Error,
        depth: Int = 0,
        matching match: (NSError) -> Bool
    ) -> Bool {
        guard depth < 4 else { return false }
        let nsError = error as NSError
        if match(nsError) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error,
           containsError(underlying, depth: depth + 1, matching: match) {
            return true
        }
        return Mirror(reflecting: error).children.contains { child in
            guard let wrapped = child.value as? Error else { return false }
            return containsError(wrapped, depth: depth + 1, matching: match)
        }
    }
}

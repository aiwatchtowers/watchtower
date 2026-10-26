import Foundation

/// An `X.Y.Z` app version, compared numerically. A leading `v` and any
/// suffix after the patch (`-dev`, `-12-gabc-dirty`, `+build`) are ignored.
package struct LearnVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    package let major: Int
    package let minor: Int
    package let patch: Int

    package init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// nil for anything that does not start with `X.Y.Z` ("dev", "next").
    package init?(_ string: String) {
        let bare = string.hasPrefix("v") ? string.dropFirst() : Substring(string)
        let core = bare.prefix { $0 != "-" && $0 != "+" }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part in part.allSatisfy(\.isASCIIDigit) ? Int(part) : nil }
        guard numbers.count == 3 else { return nil }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    package static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    package var description: String { "\(major).\(minor).\(patch)" }

    /// "0.25": what a NEW IN / UPDATED IN badge shows.
    package var majorMinor: String { "\(major).\(minor)" }

    /// The badge text for a card's `since`; the raw string when it is not a
    /// version (`next` on a dev build).
    package static func badge(_ since: String) -> String {
        Self(since)?.majorMinor ?? since
    }
}

/// Which cards are new on this launch (plan D3, design §9.5). Remembers per
/// workspace the version the app last ran and, after an update, the version
/// it was updated from and when, for the 14-day badge window.
package struct LearnVersionPolicy {
    package static let newWindow: TimeInterval = 14 * 24 * 60 * 60

    private let defaults: UserDefaults
    private let workspace: String

    package init(defaults: UserDefaults = .standard, workspace: String) {
        self.defaults = defaults
        self.workspace = workspace
    }

    var lastVersionKey: String { "learn.lastVersion.\(workspace)" }
    var newSinceKey: String { "learn.newSince.\(workspace)" }
    var newAfterKey: String { "learn.newAfter.\(workspace)" }

    /// The version cards must be newer than to be new, or nil when nothing is
    /// new: a fresh install, a dev build, no update, or the window is over.
    /// `onboardingFinished` = onboarding was finished before this launch.
    /// Idempotent within a launch; records the running version.
    package func newAfter(currentVersion: String, onboardingFinished: Bool, now: Date) -> LearnVersion? {
        // A dev build is a fresh install and leaves the release builds' memory alone.
        guard let current = LearnVersion(currentVersion) else { return nil }
        let last = defaults.string(forKey: lastVersionKey).flatMap(LearnVersion.init)
        defaults.set(current.description, forKey: lastVersionKey)
        switch last {
        case nil where onboardingFinished:
            // The first release with Learn on an install in use: updated
            // from the previous minor, so this version's cards are new.
            startWindow(after: Self.previousMinor(of: current), now: now)
        case nil:
            // A fresh install: every card is simply unseen.
            clearWindow()
            return nil
        case let last? where last < current:
            startWindow(after: last, now: now)
        default:
            break
        }
        guard let since = defaults.object(forKey: newSinceKey) as? Date,
              let after = defaults.string(forKey: newAfterKey).flatMap(LearnVersion.init),
              now.timeIntervalSince(since) < Self.newWindow,
              after < current
        else { return nil }
        return after
    }

    private func startWindow(after: LearnVersion, now: Date) {
        defaults.set(now, forKey: newSinceKey)
        defaults.set(after.description, forKey: newAfterKey)
    }

    private func clearWindow() {
        defaults.removeObject(forKey: newSinceKey)
        defaults.removeObject(forKey: newAfterKey)
    }

    static func previousMinor(of version: LearnVersion) -> LearnVersion {
        version.minor > 0
            ? LearnVersion(major: version.major, minor: version.minor - 1, patch: 0)
            : LearnVersion(major: max(version.major - 1, 0), minor: 0, patch: 0)
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

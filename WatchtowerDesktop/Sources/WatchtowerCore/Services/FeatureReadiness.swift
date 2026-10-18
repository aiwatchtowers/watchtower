import Foundation

/// Per-feature readiness, pure: every input (the clock included) comes in
/// `ReadinessInputs`. Precedence is fixed: off > needsSource > ready >
/// needsSource(.jiraBoards) > needsDigests > daemonStopped > preparing > error >
/// waitingForSync > scheduled.
package enum FeatureReadiness {
    /// A `running` row older than this is a dead process's leftover
    /// (`reapStalePipelineRuns` only reaps it after 24 h), not a run.
    package static let preparingMaxAge: TimeInterval = 2 * 60 * 60
    /// How long the daemon must be seen down before features say so: a
    /// restart (stop, then start) stays well under it, so it never flickers.
    package static let daemonDownGrace: TimeInterval = 30

    /// `config.DefaultPollInterval` in Go, in minutes.
    static let defaultPollMinutes = 15
    /// The people cards throttle (`phasePeopleCards` in `internal/daemon/daemon.go`).
    static let peopleInterval: TimeInterval = 24 * 60 * 60
    /// `DefaultIdeasMineIntervalHours` / `DefaultStreamsIntervalHours` in Go.
    static let ideasIntervalHours = 6
    static let streamsIntervalHours = 6
    /// `memoryBackfillWaitMax` in Go: the longest memory waits for a running
    /// history backfill row, from its `started_at` (#578).
    package static let memoryBackfillWaitMax: TimeInterval = 24 * 60 * 60

    package static func evaluate(_ inputs: ReadinessInputs) -> [ReadinessFeature: Readiness] {
        Dictionary(uniqueKeysWithValues: ReadinessFeature.allCases.map { ($0, readiness(of: $0, inputs)) })
    }

    /// The daemon skips these while the owner is unknown (`logNoOwnerOnce`,
    /// OWNER-02).
    package static let ownerGated: Set<ReadinessFeature> = [.briefing, .dayPlan, .inbox]

    /// With the owner unknown, an owner-gated feature promises no run: a
    /// scheduled, waiting or daemon-stopped state reads nil (the owner gap is
    /// the fix to name, even with the daemon down), so no line (Briefings, Day Plan
    /// and Inbox say why in their no-owner box; Home's card names
    /// `.ownerIdentity` instead). The other states are facts and stay.
    package static func honoringOwner(_ readiness: Readiness?, of feature: ReadinessFeature, ownerKnown: Bool) -> Readiness? {
        guard !ownerKnown, ownerGated.contains(feature) else { return readiness }
        switch readiness {
        case .scheduled, .waitingForSync, .daemonStopped: return nil
        default: return readiness
        }
    }

    private static func readiness(of feature: ReadinessFeature, _ inputs: ReadinessInputs) -> Readiness {
        if let id = feature.featureID, inputs.disabledFeatureIDs.contains(id) { return .off }
        if !feature.source.isConnected(in: inputs.connected) { return .needsSource(feature.source) }
        if inputs.contentPresent.contains(feature) { return .ready }
        // Jira with no board picked never syncs: say so instead of an ETA
        // (#572) — for Jira's features, and for Jira-or-mail ones while Jira
        // is their only connected source.
        if !inputs.jiraBoardsSelected, waitsOnJiraBoards(feature, inputs.connected) {
            return .needsSource(.jiraBoards)
        }
        if feature.runsOnlyWithDigests, let digests = ReadinessFeature.digests.featureID,
           inputs.disabledFeatureIDs.contains(digests) {
            return .needsDigests
        }
        if isDaemonDown(running: inputs.daemonRunning, since: inputs.daemonNotRunningSince, now: inputs.now) {
            return .daemonStopped
        }

        let syncing = inputs.syncProgress?.isSyncing(now: inputs.now) == true
        let syncDetail = syncing ? inputs.syncProgress?.summary : nil
        if let pipeline = feature.pipelineName, let run = inputs.latestRuns[pipeline] {
            if run.status == "running", inputs.daemonRunning,
               inputs.now.timeIntervalSince(run.startedAt) < preparingMaxAge {
                return .preparing(detail: syncDetail)
            }
            // While memory waits for the history backfill, an older failed
            // run is not what holds it (#578): the wait line wins.
            if run.status == "error", !(feature == .memory && memoryWaitsForHistory(inputs)) {
                return .error(message: run.errorMessage)
            }
        }
        if feature.readsSyncedData, inputs.connected.slack, inputs.lastSyncTime == nil {
            return .waitingForSync(detail: syncDetail)
        }
        return .scheduled(eta(of: feature, inputs, syncing: syncing))
    }

    private static func waitsOnJiraBoards(_ feature: ReadinessFeature, _ connected: ConnectedSources) -> Bool {
        switch feature.source {
        case .jira: true
        case .jiraOrMail: !connected.mail
        default: false
        }
    }

    /// Down for the grace period: every "preparing", "retries" or ETA would
    /// be a promise nothing keeps until the daemon is started. Also the
    /// app-wide banner's rule (`ReadinessCenter.daemonDown`).
    package static func isDaemonDown(running: Bool, since: Date?, now: Date) -> Bool {
        guard !running, let since else { return false }
        return now.timeIntervalSince(since) >= daemonDownGrace
    }

    private static func eta(of feature: ReadinessFeature, _ inputs: ReadinessInputs, syncing: Bool) -> Eta {
        let cycle: Eta = syncing ? .afterCurrentSync : .nextCycle(minutes: inputs.pollIntervalMinutes)
        let now = inputs.now
        switch feature {
        case .briefing:
            // Fresh install, dual path with Go's `briefingFresh`
            // (internal/daemon/daemon.go): no `briefings` row at all and no
            // `last_briefing.txt`. Content here is "any briefings row".
            let fresh = !inputs.contentPresent.contains(.briefing) && inputs.stamps.lastBriefing == nil
            return daily(fresh: fresh, last: inputs.stamps.lastBriefing, hour: inputs.briefingHour, now: now, cycle: cycle)
        case .dayPlan:
            // Fresh install, dual path with Go's `dayPlanFresh`
            // (internal/daemon/daemon.go): no `day_plans` row at all. The
            // daemon's last day-plan date is in memory only, so there is no
            // stamp to read.
            let fresh = !inputs.contentPresent.contains(.dayPlan)
            return daily(fresh: fresh, last: nil, hour: inputs.dayPlanHour, now: now, cycle: cycle)
        case .peopleCards:
            guard let last = inputs.stamps.lastPeople, now.timeIntervalSince(last) < peopleInterval else { return cycle }
            return .inAboutADay
        case .ideas:
            return interval(last: inputs.stamps.lastIdeas, hours: ideasIntervalHours, now: now) ?? cycle
        case .streamDigests:
            return interval(last: inputs.stamps.lastStreams, hours: streamsIntervalHours, now: now) ?? cycle
        case .memory:
            return memoryWaitsForHistory(inputs) ? .afterHistoryLoads : cycle
        case .slackSync, .digests, .tracks, .inbox, .knowledgeIndex, .calendar, .jira:
            return cycle
        }
    }

    /// Dual path with Go's `memoryWaitsForBackfill` (internal/daemon/daemon.go):
    /// only before memory's first successful run, never under the kill switch
    /// (`sync.backfill_days <= 0`), and only while a backfill row is running
    /// and started less than `memoryBackfillWaitMax` ago; paused, done and off
    /// rows never hold it.
    private static func memoryWaitsForHistory(_ inputs: ReadinessInputs) -> Bool {
        guard !inputs.backfillOff, !inputs.memoryHasRun else { return false }
        return inputs.runningBackfillStarts.contains { inputs.now.timeIntervalSince($0) < memoryBackfillWaitMax }
    }

    /// A once-a-day pipeline's gate, as Go's `shouldRunBriefing`: already ran
    /// today → tomorrow; before the hour → today at the hour, unless fresh
    /// (P4 runs the first one in the next cycle); otherwise this cycle.
    private static func daily(fresh: Bool, last: Date?, hour: Int, now: Date, cycle: Eta) -> Eta {
        if fresh { return cycle }
        let calendar = Calendar.current
        if let last, calendar.isDate(last, inSameDayAs: now) { return .at(hour: hour, tomorrow: true) }
        if calendar.component(.hour, from: now) < hour { return .at(hour: hour, tomorrow: false) }
        return cycle
    }

    /// The whole hours left of an `hours`-long throttle since `last`; nil when
    /// there is no stamp or the throttle has passed.
    private static func interval(last: Date?, hours: Int, now: Date) -> Eta? {
        guard let last else { return nil }
        let left = Double(hours) * 3600 - now.timeIntervalSince(last)
        guard left > 0 else { return nil }
        return .inHours(min(hours, Int((left / 3600).rounded(.up))))
    }

    /// The feature a Turn on for `feature` switches on, which also keys its
    /// progress and error: Slack Digests while `feature` waits on it, and
    /// while a Slack Digests Turn on failed (`digestsTurnOnFailed`: an
    /// enable whose restart failed leaves Digests on, the state moves on,
    /// and only its retry restarts, #575); otherwise the feature's own id.
    package static func turnOnFeatureID(
        for feature: ReadinessFeature, readiness: Readiness?, digestsTurnOnFailed: Bool
    ) -> String? {
        guard feature.runsOnlyWithDigests, readiness != .off else { return feature.featureID }
        if readiness == .needsDigests || digestsTurnOnFailed { return ReadinessFeature.digests.featureID }
        return feature.featureID
    }

    // MARK: - Wording

    package static func phrase(_ eta: Eta) -> String {
        switch eta {
        case .afterCurrentSync: "after this sync"
        case .nextCycle(let minutes): "within ~\(minutes) min"
        case let .at(hour, tomorrow): "\(tomorrow ? "tomorrow" : "today") at \(String(format: "%02d:00", hour))"
        case .inAboutADay: "in about a day"
        case .inHours(let hours): "in about \(hours) h"
        case .afterHistoryLoads: "waiting for history to load"
        }
    }

    /// One UI line per state.
    package static func line(_ readiness: Readiness) -> String {
        switch readiness {
        case .off: "Off — Turn on"
        case .needsSource(.ownerIdentityPending(let name)): "Waiting for your \(name) identity…"
        case .needsSource(let source): "\(source.actionTitle) to get this"
        // Every place that shows it follows it with a Turn on Slack Digests button.
        case .needsDigests: "Needs Slack Digests"
        case .ready: "Ready — Open"
        case .daemonStopped: "Watchtower isn't running"
        case .preparing(let detail): withDetail("Preparing now", detail)
        case .error(let message): withDetail("Didn't work yet — retries automatically", shortError(message))
        case .waitingForSync(let detail): withDetail("Starts after the first sync", detail)
        case .scheduled(let eta): capitalizedFirst(phrase(eta))
        }
    }

    private static func withDetail(_ text: String, _ detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return text }
        return "\(text) · \(detail)"
    }

    /// The first line of an `error_msg`, capped so it fits one UI line.
    private static func shortError(_ message: String) -> String {
        let first = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 80 ? String(trimmed.prefix(79)) + "…" : trimmed
    }

    private static func capitalizedFirst(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    // MARK: - Config

    /// `sync.poll_interval` (a Go duration: "15m", "1h", "900s", "1h30m") in
    /// whole minutes, rounded up; nil, garbage or zero → 15.
    package static func parsePollInterval(_ value: String?) -> Int {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return defaultPollMinutes }
        let unitSeconds: [Character: Double] = ["h": 3600, "m": 60, "s": 1]
        var seconds = 0.0
        var number = ""
        for char in value {
            if char.isNumber || char == "." {
                number.append(char)
            } else if let unit = unitSeconds[char], let amount = Double(number) {
                seconds += amount * unit
                number = ""
            } else {
                return defaultPollMinutes
            }
        }
        guard number.isEmpty, seconds > 0 else { return defaultPollMinutes }
        return Int((seconds / 60).rounded(.up))
    }
}

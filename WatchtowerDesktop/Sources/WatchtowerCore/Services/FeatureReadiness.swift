import Foundation

/// Per-feature readiness, pure: every input (the clock included) comes in
/// `ReadinessInputs`. Precedence is fixed: off > needsSource > ready >
/// preparing > error > waitingForSync > scheduled.
package enum FeatureReadiness {
    /// A `running` row older than this is a dead process's leftover
    /// (`reapStalePipelineRuns` only reaps it after 24 h), not a run.
    package static let preparingMaxAge: TimeInterval = 2 * 60 * 60

    /// `config.DefaultPollInterval` in Go, in minutes.
    static let defaultPollMinutes = 15
    /// The people cards throttle (`phasePeopleCards` in `internal/daemon/daemon.go`).
    static let peopleInterval: TimeInterval = 24 * 60 * 60
    /// `DefaultIdeasMineIntervalHours` / `DefaultStreamsIntervalHours` in Go.
    static let ideasIntervalHours = 6
    static let streamsIntervalHours = 6

    package static func evaluate(_ inputs: ReadinessInputs) -> [ReadinessFeature: Readiness] {
        Dictionary(uniqueKeysWithValues: ReadinessFeature.allCases.map { ($0, readiness(of: $0, inputs)) })
    }

    /// The daemon skips these while the owner is unknown (`logNoOwnerOnce`,
    /// OWNER-02).
    package static let ownerGated: Set<ReadinessFeature> = [.briefing, .dayPlan, .inbox]

    /// With the owner unknown, an owner-gated feature promises no run: a
    /// scheduled or waiting state reads nil, so no line (Briefings, Day Plan
    /// and Inbox say why in their no-owner box; Home's card names
    /// `.ownerIdentity` instead). The other states are facts and stay.
    package static func honoringOwner(_ readiness: Readiness?, of feature: ReadinessFeature, ownerKnown: Bool) -> Readiness? {
        guard !ownerKnown, ownerGated.contains(feature) else { return readiness }
        switch readiness {
        case .scheduled, .waitingForSync: return nil
        default: return readiness
        }
    }

    private static func readiness(of feature: ReadinessFeature, _ inputs: ReadinessInputs) -> Readiness {
        if let id = feature.featureID, inputs.disabledFeatureIDs.contains(id) { return .off }
        if !feature.source.isConnected(in: inputs.connected) { return .needsSource(feature.source) }
        if inputs.contentPresent.contains(feature) { return .ready }

        let syncing = inputs.syncProgress?.isSyncing(now: inputs.now) == true
        let syncDetail = syncing ? inputs.syncProgress?.summary : nil
        if let pipeline = feature.pipelineName, let run = inputs.latestRuns[pipeline] {
            if run.status == "running", inputs.daemonRunning,
               inputs.now.timeIntervalSince(run.startedAt) < preparingMaxAge {
                return .preparing(detail: syncDetail)
            }
            if run.status == "error" { return .error(message: run.errorMessage) }
        }
        if feature.readsSyncedData, inputs.connected.slack, inputs.lastSyncTime == nil {
            return .waitingForSync(detail: syncDetail)
        }
        return .scheduled(eta(of: feature, inputs, syncing: syncing))
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
        case .slackSync, .digests, .tracks, .memory, .inbox, .knowledgeIndex, .calendar, .jira:
            return cycle
        }
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

    // MARK: - Wording

    package static func phrase(_ eta: Eta) -> String {
        switch eta {
        case .afterCurrentSync: "after this sync"
        case .nextCycle(let minutes): "within ~\(minutes) min"
        case let .at(hour, tomorrow): "\(tomorrow ? "tomorrow" : "today") at \(String(format: "%02d:00", hour))"
        case .inAboutADay: "in about a day"
        case .inHours(let hours): "in about \(hours) h"
        }
    }

    /// One UI line per state.
    package static func line(_ readiness: Readiness) -> String {
        switch readiness {
        case .off: "Off — Turn on"
        case .needsSource(.ownerIdentityPending(let name)): "Waiting for your \(name) identity…"
        case .needsSource(let source): "Connect \(source.displayName) to get this"
        case .ready: "Ready — Open"
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

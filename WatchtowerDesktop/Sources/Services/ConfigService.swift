import AppKit
import Foundation
import Yams
import WatchtowerCore

@MainActor
@Observable
final class ConfigService {
    var activeWorkspace: String?
    var syncInterval: String?
    var syncWorkers: Int?
    var syncThreads: Bool = true
    var initialHistoryDays: Int?
    /// Display-only, like `dayPlanEnabled` and `ideasEnabled`: `reload()`
    /// parses it and other views read it, but `save()` never writes
    /// `digest.enabled` back. The Feature Manager CLI (`watchtower features
    /// enable|disable slack-digests`) is the single writer of every feature
    /// on/off key — a second writer here would race it, and because this
    /// property defaults to `false` when the config has no digest section at
    /// all, an ordinary Save on a fresh install used to materialize
    /// `digest.enabled: false`, which is exactly the legacy "all AI off"
    /// signature `config.MigrateFeatureGates` looks for.
    var digestEnabled: Bool = false
    var digestModel: String?
    var digestMinMessages: Int?
    var digestLanguage: String?
    var aiModel: String?
    var aiModelLight: String?
    var aiModelStrong: String?
    var aiOllamaURL: String?
    var aiWorkers: Int?
    var analysisLegacyMode: Bool = false
    var briefingHour: Int = 8
    var aiProvider: String?
    var claudePath: String?
    var codexPath: String?
    var calendarEnabled: Bool = false
    var calendarSyncDaysAhead: Int = 2
    /// Days of past events kept synced (`calendar.history_days`), the same
    /// knob widening the Go syncers' timeMin. Read-only here — `save()`
    /// preserves whatever is on disk via its merge.
    var calendarHistoryDays: Int = 14
    var gmailEnabled: Bool = false
    var jiraFeatures: [String: Bool] = [:]
    /// Display-only — `save()` never writes `day_plan.enabled`. See
    /// `digestEnabled`.
    var dayPlanEnabled: Bool = true
    var dayPlanHour: Int = 8
    var workingHoursStart: String = "09:00"
    var workingHoursEnd: String = "19:00"
    var maxTimeblocks: Int = 3
    var minBacklog: Int = 3
    var maxBacklog: Int = 8
    var transcriptAudioRetentionDays: Int = 30
    /// Display-only — `save()` never writes `ideas.enabled`. See
    /// `digestEnabled`.
    var ideasEnabled: Bool = true
    var ideasMineIntervalHours: Int = 6
    var parseError: String?

    private let configPath: String
    /// Raw YAML dictionary — preserved for round-trip editing
    private var rawYAML: [String: Any] = [:]

    convenience init() {
        self.init(configPath: Constants.configPath)
    }

    /// Test-friendly initializer accepting an explicit config file path.
    init(configPath: String) {
        self.configPath = configPath
        reload()
    }

    func reload() {
        guard let data = FileManager.default.contents(atPath: configPath),
              let str = String(data: data, encoding: .utf8) else {
            return
        }

        do {
            guard let yaml = try Yams.load(yaml: str) as? [String: Any] else { return }
            rawYAML = yaml

            activeWorkspace = yaml["active_workspace"] as? String

            if let sync = yaml["sync"] as? [String: Any] {
                syncInterval = sync["poll_interval"] as? String
                    ?? (sync["poll_interval"].flatMap { "\($0)" })
                syncWorkers = sync["workers"] as? Int
                syncThreads = (sync["sync_threads"] as? Bool) ?? true
                initialHistoryDays = sync["initial_history_days"] as? Int
            }

            if let digest = yaml["digest"] as? [String: Any] {
                digestEnabled = (digest["enabled"] as? Bool) ?? false
                digestModel = digest["model"] as? String
                digestMinMessages = digest["min_messages"] as? Int
                digestLanguage = digest["language"] as? String
            }

            if let analysis = yaml["analysis"] as? [String: Any] {
                analysisLegacyMode = (analysis["legacy_mode"] as? Bool) ?? false
            }

            if let briefing = yaml["briefing"] as? [String: Any] {
                briefingHour = (briefing["hour"] as? Int) ?? 8
            }

            if let ai = yaml["ai"] as? [String: Any] {
                aiModel = ai["model"] as? String
                aiWorkers = ai["workers"] as? Int
                aiProvider = ai["provider"] as? String
                aiOllamaURL = ai["ollama_url"] as? String
                if let models = ai["models"] as? [String: Any] {
                    aiModelLight = models["light"] as? String
                    aiModelStrong = models["strong"] as? String
                }
            }

            claudePath = yaml["claude_path"] as? String
            codexPath = yaml["codex_path"] as? String

            if let calendar = yaml["calendar"] as? [String: Any] {
                calendarEnabled = (calendar["enabled"] as? Bool) ?? false
                calendarSyncDaysAhead = (calendar["sync_days_ahead"] as? Int) ?? 2
                calendarHistoryDays = (calendar["history_days"] as? Int) ?? 14
            }

            if let gmail = yaml["gmail"] as? [String: Any] {
                gmailEnabled = (gmail["enabled"] as? Bool) ?? false
            }

            if let jira = yaml["jira"] as? [String: Any],
               let features = jira["features"] as? [String: Bool] {
                jiraFeatures = features
            } else {
                jiraFeatures = [:]
            }

            if let transcripts = yaml["transcripts"] as? [String: Any] {
                transcriptAudioRetentionDays = (transcripts["audio_retention_days"] as? Int) ?? 30
            }

            if let ideas = yaml["ideas"] as? [String: Any] {
                ideasEnabled = (ideas["enabled"] as? Bool) ?? true
                ideasMineIntervalHours = (ideas["mine_interval_hours"] as? Int) ?? 6
            }

            if let dayPlan = yaml["day_plan"] as? [String: Any] {
                dayPlanEnabled = (dayPlan["enabled"] as? Bool) ?? true
                dayPlanHour = (dayPlan["hour"] as? Int) ?? 8
                workingHoursStart = (dayPlan["working_hours_start"] as? String) ?? "09:00"
                workingHoursEnd = (dayPlan["working_hours_end"] as? String) ?? "19:00"
                maxTimeblocks = (dayPlan["max_timeblocks"] as? Int) ?? 3
                minBacklog = (dayPlan["min_backlog"] as? Int) ?? 3
                maxBacklog = (dayPlan["max_backlog"] as? Int) ?? 8
            }

            parseError = nil
        } catch {
            parseError = error.localizedDescription
        }
    }

    /// Writes the ai: block (provider, legacy model, per-tier models, ollama
    /// URL, workers), removing empty values so cleared overrides disappear
    /// from the yaml instead of lingering as empty strings.
    private func applyAISection(to yaml: inout [String: Any]) {
        var ai = (yaml["ai"] as? [String: Any]) ?? [:]
        if let val = aiModel, !val.isEmpty { ai["model"] = val } else { ai.removeValue(forKey: "model") }
        if let val = aiWorkers { ai["workers"] = val } else { ai.removeValue(forKey: "workers") }
        if let val = aiProvider, !val.isEmpty { ai["provider"] = val } else { ai.removeValue(forKey: "provider") }
        if let val = aiOllamaURL, !val.isEmpty { ai["ollama_url"] = val } else { ai.removeValue(forKey: "ollama_url") }
        var aiModels = (ai["models"] as? [String: Any]) ?? [:]
        if let val = aiModelLight, !val.isEmpty { aiModels["light"] = val } else { aiModels.removeValue(forKey: "light") }
        if let val = aiModelStrong, !val.isEmpty { aiModels["strong"] = val } else { aiModels.removeValue(forKey: "strong") }
        if !aiModels.isEmpty { ai["models"] = aiModels } else { ai.removeValue(forKey: "models") }
        if !ai.isEmpty { yaml["ai"] = ai } else { yaml.removeValue(forKey: "ai") }
    }

    func save() throws {
        // Re-read the config file right before writing instead of using the
        // in-memory `rawYAML` snapshot captured at the last reload(). Between
        // load and save, an external process (e.g. `watchtower jira login`,
        // `watchtower calendar login`) may have written sections we don't
        // own (jira, google token, etc). Merging onto a stale snapshot would
        // silently discard those. Fall back to `rawYAML` only if the file is
        // gone or unreadable.
        var yaml = currentYAMLOnDisk() ?? rawYAML

        yaml["active_workspace"] = activeWorkspace

        // Sync section
        var sync = (yaml["sync"] as? [String: Any]) ?? [:]
        if let val = syncInterval, !val.isEmpty { sync["poll_interval"] = val } else { sync.removeValue(forKey: "poll_interval") }
        if let val = syncWorkers { sync["workers"] = val } else { sync.removeValue(forKey: "workers") }
        sync["sync_threads"] = syncThreads
        if let val = initialHistoryDays { sync["initial_history_days"] = val } else { sync.removeValue(forKey: "initial_history_days") }
        if !sync.isEmpty { yaml["sync"] = sync } else { yaml.removeValue(forKey: "sync") }

        // Digest section — `enabled` is deliberately not written, see the
        // `digestEnabled` property.
        var digest = (yaml["digest"] as? [String: Any]) ?? [:]
        if let val = digestModel, !val.isEmpty { digest["model"] = val } else { digest.removeValue(forKey: "model") }
        if let val = digestMinMessages { digest["min_messages"] = val } else { digest.removeValue(forKey: "min_messages") }
        if let val = digestLanguage, !val.isEmpty { digest["language"] = val } else { digest.removeValue(forKey: "language") }
        if !digest.isEmpty { yaml["digest"] = digest } else { yaml.removeValue(forKey: "digest") }

        // Briefing section
        var briefing = (yaml["briefing"] as? [String: Any]) ?? [:]
        briefing["hour"] = briefingHour
        yaml["briefing"] = briefing

        // AI section
        applyAISection(to: &yaml)

        // Calendar section
        var calendarDict = (yaml["calendar"] as? [String: Any]) ?? [:]
        calendarDict["enabled"] = calendarEnabled
        calendarDict["sync_days_ahead"] = calendarSyncDaysAhead
        yaml["calendar"] = calendarDict

        // Gmail section
        var gmailDict = (yaml["gmail"] as? [String: Any]) ?? [:]
        gmailDict["enabled"] = gmailEnabled
        yaml["gmail"] = gmailDict

        // Ideas section — `enabled` is deliberately not written, see the
        // `ideasEnabled` property.
        var ideas = (yaml["ideas"] as? [String: Any]) ?? [:]
        ideas["mine_interval_hours"] = ideasMineIntervalHours
        yaml["ideas"] = ideas

        // Day Plan section — `enabled` is deliberately not written, see the
        // `dayPlanEnabled` property.
        var dayPlan = (yaml["day_plan"] as? [String: Any]) ?? [:]
        dayPlan["hour"] = dayPlanHour
        dayPlan["working_hours_start"] = workingHoursStart
        dayPlan["working_hours_end"] = workingHoursEnd
        dayPlan["max_timeblocks"] = maxTimeblocks
        dayPlan["min_backlog"] = minBacklog
        dayPlan["max_backlog"] = maxBacklog
        yaml["day_plan"] = dayPlan

        // Transcripts section
        var transcripts = (yaml["transcripts"] as? [String: Any]) ?? [:]
        transcripts["audio_retention_days"] = transcriptAudioRetentionDays
        yaml["transcripts"] = transcripts

        // Claude path override
        if let val = claudePath, !val.isEmpty { yaml["claude_path"] = val } else { yaml.removeValue(forKey: "claude_path") }

        // Codex path override
        if let val = codexPath, !val.isEmpty { yaml["codex_path"] = val } else { yaml.removeValue(forKey: "codex_path") }

        let output = try Yams.dump(object: yaml, allowUnicode: true)

        let dir = (configPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try output.write(toFile: configPath, atomically: true, encoding: .utf8)
        // Restrict permissions to owner-only (config contains Slack token)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath)

        rawYAML = yaml
    }

    /// Load the current on-disk config as a raw YAML dictionary, without
    /// touching any of the published `@Observable` properties. Used by
    /// `save()` to merge onto the freshest state rather than a stale snapshot.
    private func currentYAMLOnDisk() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: configPath),
              let str = String(data: data, encoding: .utf8),
              let yaml = try? Yams.load(yaml: str) as? [String: Any] else {
            return nil
        }
        return yaml
    }

    func openInEditor() {
        let url = URL(fileURLWithPath: configPath)
        NSWorkspace.shared.open(url)
    }

    func revealInFinder() {
        let url = URL(fileURLWithPath: configPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

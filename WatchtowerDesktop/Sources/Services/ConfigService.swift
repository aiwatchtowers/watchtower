import AppKit
import ChatWire
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
    /// `sync.backfill_days`, read only (readiness's kill-switch check); nil = unset.
    var backfillDays: Int?
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
    var digestMinMessages: Int?
    var digestLanguage: String?
    private var providerBuckets: [String: [String: Any]] = [:]
    private var editedProviderBuckets: [String: [String: Any]] = [:]
    var aiModel: String?
    @ObservationIgnored private var editedModelTiers: Set<String> = []
    var aiModelLight: String? { didSet { editedModelTiers.insert("light") } }
    var aiModelStrong: String? { didSet { editedModelTiers.insert("strong") } }
    var aiOllamaURL: String?
    var aiWorkers: Int?
    var briefingHour: Int = 8
    var aiProvider: String?
    var aiFallbackEnabled = false
    var aiFallbackProvider: String?
    @ObservationIgnored private var loadedFallbackEnabled = false
    @ObservationIgnored private var loadedFallbackProvider: String?
    let providerConnection: ProviderConnection
    let providerHealth = ProviderSettingsHealth()
    var claudePath: String?
    var codexPath: String?
    /// `workbench.default_agent` (board #399, D1): the agent a new workbench
    /// session, Work on It and a phone start launch unless the owner picks
    /// the other one. Go twin: `config.WorkbenchConfig.Agent()` — a missing,
    /// empty, unknown or wrong-case value reads Claude Code.
    var workbenchDefaultAgent: AgentKind = .claude
    var calendarEnabled: Bool = true
    /// Mirrors Go's `DefaultCalendarSyncDaysAhead` (internal/config/defaults.go).
    /// `save()` always writes `calendar.sync_days_ahead`, so a Swift default
    /// that drifts from Go's silently rewrites the daemon's horizon the first
    /// time anything in Settings saves.
    static let defaultCalendarSyncDaysAhead = 7
    var calendarSyncDaysAhead: Int = ConfigService.defaultCalendarSyncDaysAhead
    /// Days of past events kept synced (`calendar.history_days`), the same
    /// knob widening the Go syncers' timeMin. Read-only here — `save()`
    /// preserves whatever is on disk via its merge.
    var calendarHistoryDays: Int = 30
    var gmailEnabled: Bool = true
    var jiraFeatures: [String: Bool] = [:]
    /// Display-only — `save()` never writes `day_plan.enabled`. See
    /// `digestEnabled`.
    var dayPlanEnabled: Bool = true
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
    /// `privacy.purge_revoked_data` (board #601): nil = absent, the build
    /// default applies. Written only once the owner sets it; the effective
    /// value (policy > this > build default) comes from Go,
    /// `watchtower accounts purges --json`.
    var purgeRevokedData: Bool? // swiftlint:disable:this discouraged_optional_boolean
    /// The last `save()` wrote a new purge setting. The daemon reads the
    /// config only at startup, so Settings restarts it after such a Save.
    private(set) var lastSaveChangedPurge = false
    var parseError: String?
    /// `ai.background_runs`, the owner's background AI answer, raw as read
    /// (nil when absent). Read only: its one writer is
    /// `watchtower ai background allow|pause`, and `save()` never writes it.
    private(set) var backgroundRuns: String?
    /// config.yaml exists but could not be read or parsed at the last read of
    /// `backgroundRuns`, so the answer is unknown (reads paused, as in Go).
    private(set) var backgroundRunsUnreadable = false
    /// `ai.provider` as last loaded or saved, never the unsaved edit: the
    /// agent Settings → AI → Background AI names.
    private(set) var savedAIProvider: String?
    let routingApplication: ProviderRoutingApplication

    private let configPath: String
    /// The config write lock, the read inside it and the write
    /// (`ConfigFileAccess.live`; a test records them).
    @ObservationIgnored private let fileAccess: ConfigFileAccess
    /// Raw YAML dictionary — preserved for round-trip editing
    private var rawYAML: [String: Any] = [:]
    /// `calendar.enabled`/`gmail.enabled` as last read from or written to
    /// disk. `save()` writes a switch only when this instance changed it: the
    /// CLI turns a switch on when Google connects (`google add`), and a
    /// Settings window loaded before that must not switch it back off with an
    /// unrelated Save (#740) — nor materialize `false` on a fresh install.
    private var diskCalendarEnabled = true
    private var diskGmailEnabled = true
    /// `privacy.purge_revoked_data` as last read from or written to disk.
    private var diskPurgeRevokedData: Bool? // swiftlint:disable:this discouraged_optional_boolean
    /// The providers' capability rows: the fallback pair is their
    /// `reserve_peer` (LLMTRANSPORT-01), never a Swift copy of the rule.
    @ObservationIgnored private let catalog: AIModelCatalog

    /// The editable fields as the last `reload()` or `save()` left them.
    @ObservationIgnored private var loadedFields: [String: String] = [:]

    convenience init() {
        self.init(configPath: Constants.configPath)
    }

    /// Test-friendly initializer accepting an explicit config file path.
    init(
        configPath: String,
        routingRead: (() async throws -> ChatRoutingStatus)? = nil,
        connection: ProviderConnection? = nil,
        catalog: AIModelCatalog = .shared,
        fileAccess: ConfigFileAccess = .live
    ) {
        self.catalog = catalog
        self.fileAccess = fileAccess
        providerConnection = connection ?? ProviderConnection()
        routingApplication = ProviderRoutingApplication(read: routingRead ?? {
            guard let runner = ProcessCLIRunner.makeDefault() else { throw CLIRunnerError.binaryNotFound }
            let data = try await runner.run(args: ["--config", configPath, "ai", "routing-status"], timeout: 5)
            return try ChatRoutingStatus.parse(data)
        })
        self.configPath = configPath
        reload()
    }

    /// One read of config.yaml, shared by `reload()` and
    /// `reloadBackgroundRuns()` so "unreadable" means the same in both. Only a
    /// confirmed file-not-found is `absent` (a missing file keeps the
    /// defaults); a file that is present but cannot be read, decoded or
    /// parsed — or a path that cannot be checked, such as one in a directory
    /// this process cannot enter — is a third state (#740), as in Go.
    enum ConfigRead {
        case absent
        /// A blank, comments-only or `null` document: an empty config, as the Go CLI reads it.
        case empty
        case mapping([String: Any])
        case unreadable(reason: String)
    }

    static func readConfig(atPath path: String) -> ConfigRead {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .absent
        } catch {
            return .unreadable(reason: "config.yaml can't be read")
        }
        guard let str = String(data: data, encoding: .utf8) else {
            return .unreadable(reason: "config.yaml is not UTF-8 text")
        }
        let loaded: Any?
        do { loaded = try Yams.load(yaml: str) } catch {
            return .unreadable(reason: error.localizedDescription)
        }
        guard let loaded, !(loaded is NSNull) else { return .empty }
        guard let yaml = loaded as? [String: Any] else {
            return .unreadable(reason: "config.yaml is not a YAML mapping")
        }
        return .mapping(yaml)
    }

    func reload() {
        resetProviderOperations()
        routingApplication.configurationReloaded()
        defer { resetModelEditTracking() }
        let read = Self.readConfig(atPath: configPath)
        adoptBackgroundRuns(read)
        guard case .mapping(let yaml) = read else {
            if case .unreadable(let reason) = read { parseError = reason }
            return
        }
        adoptRawConfiguration(yaml)

        if let sync = yaml["sync"] as? [String: Any] {
            syncInterval = sync["poll_interval"] as? String
                ?? (sync["poll_interval"].flatMap { "\($0)" })
            syncWorkers = sync["workers"] as? Int
            syncThreads = (sync["sync_threads"] as? Bool) ?? true
            initialHistoryDays = sync["initial_history_days"] as? Int
            backfillDays = sync["backfill_days"] as? Int
        }

        if let digest = yaml["digest"] as? [String: Any] {
            digestEnabled = (digest["enabled"] as? Bool) ?? false
            digestMinMessages = digest["min_messages"] as? Int
            digestLanguage = digest["language"] as? String
        }

        if let briefing = yaml["briefing"] as? [String: Any] {
            briefingHour = (briefing["hour"] as? Int) ?? 8
        }

        if let ai = try? Self.aiSection(yaml) {
            loadFallback(ai)
            prepareProviderModels(ai)
            aiModel = ai["model"] as? String
            aiWorkers = ai["workers"] as? Int
            aiProvider = ai["provider"] as? String
            aiOllamaURL = ai["ollama_url"] as? String
            if let models = ai["models"] as? [String: Any] {
                aiModelLight = models["light"] as? String
                aiModelStrong = models["strong"] as? String
            }
        }

        loadProviderModels()
        loadCLIPaths(yaml)

        if let calendar = yaml["calendar"] as? [String: Any] {
            calendarEnabled = (calendar["enabled"] as? Bool) ?? true
            diskCalendarEnabled = calendarEnabled
            calendarSyncDaysAhead = (calendar["sync_days_ahead"] as? Int) ?? Self.defaultCalendarSyncDaysAhead
            calendarHistoryDays = (calendar["history_days"] as? Int) ?? 30
        }

        if let gmail = yaml["gmail"] as? [String: Any] {
            gmailEnabled = (gmail["enabled"] as? Bool) ?? true
            diskGmailEnabled = gmailEnabled
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

        loadDayPlan(yaml)

        purgeRevokedData = (yaml["privacy"] as? [String: Any])?["purge_revoked_data"] as? Bool
        diskPurgeRevokedData = purgeRevokedData

        parseError = nil
    }

    private func loadDayPlan(_ yaml: [String: Any]) {
        guard let dayPlan = yaml["day_plan"] as? [String: Any] else { return }
        dayPlanEnabled = (dayPlan["enabled"] as? Bool) ?? true
        workingHoursStart = (dayPlan["working_hours_start"] as? String) ?? "09:00"
        workingHoursEnd = (dayPlan["working_hours_end"] as? String) ?? "19:00"
        maxTimeblocks = (dayPlan["max_timeblocks"] as? Int) ?? 3
        minBacklog = (dayPlan["min_backlog"] as? Int) ?? 3
        maxBacklog = (dayPlan["max_backlog"] as? Int) ?? 8
    }

    /// Re-reads only `ai.background_runs` (plan Decision 12: on activation
    /// and after the Desktop's own allow/pause call). Unsaved Settings edits
    /// stay; `parseError` is left to `reload()`.
    func reloadBackgroundRuns() {
        adoptBackgroundRuns(Self.readConfig(atPath: configPath))
    }

    private func adoptBackgroundRuns(_ read: ConfigRead) {
        switch read {
        case .absent, .empty:
            backgroundRuns = nil
            backgroundRunsUnreadable = false
        case .mapping(let yaml):
            do {
                backgroundRuns = try Self.backgroundRuns(in: yaml)
                backgroundRunsUnreadable = false
            } catch {
                backgroundRuns = nil
                backgroundRunsUnreadable = true
            }
        case .unreadable:
            backgroundRuns = nil
            backgroundRunsUnreadable = true
        }
    }

    /// The key of `m` that matches `key` without regard to case, as viper
    /// reads keys; nil when none does. More than one match (`AI` and `Ai`, or
    /// `ai` and `AI`) is ambiguous and throws: Go and the Desktop could pick
    /// different ones, so both fail closed. Twin of Go's `aiconsent.lookupFold`.
    static func foldKey(_ m: [String: Any], _ key: String) throws -> String? {
        let matches = m.keys.filter { $0.caseInsensitiveCompare(key) == .orderedSame }
        guard matches.count <= 1 else {
            throw ConfigUnreadableError(reason: "\(key) appears more than once (keys differing only in case)")
        }
        return matches.first
    }

    /// The `ai` section, found as Go finds it; nil when absent or not a mapping.
    static func aiSection(_ yaml: [String: Any]) throws -> [String: Any]? {
        try foldKey(yaml, "ai").flatMap { yaml[$0] as? [String: Any] }
    }

    /// `ai.background_runs` as a string, keys matched as Go's `lookupFold`
    /// matches them; a non-string value reads as nil (absent). Throws when a
    /// key is ambiguous.
    private static func backgroundRuns(in yaml: [String: Any]) throws -> String? {
        guard let ai = try aiSection(yaml), let key = try foldKey(ai, "background_runs") else { return nil }
        return ai[key] as? String
    }

    private func adoptRawConfiguration(_ yaml: [String: Any]) {
        rawYAML = yaml
        activeWorkspace = yaml["active_workspace"] as? String
    }

    /// `calendar.enabled` is known to be off. False when config.yaml is
    /// present but unreadable — then the switch is unknown, never "off".
    var calendarSyncReadsOff: Bool {
        parseError == nil && !calendarEnabled
    }

    /// Turns `calendar.enabled` on and saves. Refuses over an unreadable
    /// config.yaml: `save()` would fall back to the last good snapshot and
    /// drop every section it does not own.
    func turnOnCalendarSync() throws {
        if let parseError { throw ConfigUnreadableError(reason: parseError) }
        calendarEnabled = true
        try save()
    }

    private func resetModelEditTracking() {
        editedModelTiers = []
        editedProviderBuckets = [:]
        loadedFields = editableFields
        savedAIProvider = aiProvider
    }

    private func modelTierEdited(_ tier: String) -> Bool {
        editedModelTiers.contains(tier)
    }

    private func prepareProviderModels(_ ai: [String: Any]) {
        providerBuckets = ai["providers"] as? [String: [String: Any]] ?? [:]
        editedProviderBuckets = [:]
        aiModelLight = nil
        aiModelStrong = nil
    }

    private func loadProviderModels() {
        if let bucket = providerBuckets[aiProvider ?? "claude"] {
            let models = bucket["models"] as? [String: Any] ?? [:]
            aiModelLight = models["light"] as? String
            aiModelStrong = models["strong"] as? String
            aiModel = nil
        }
    }

    // Twin of providers.normalizePinnedModel; empty remains provider Default.
    private static func migratedModel(_ model: String?, provider: String) -> String {
        guard let model, !model.isEmpty else { return "" }
        if provider == "claude", model.range(of: "^claude-(opus|sonnet|haiku)-[0-9]", options: .regularExpression) != nil {
            return model.components(separatedBy: "-")[1]
        }
        if provider == "codex", model.range(of: "^gpt-5(\\.[0-5])?(-|$)", options: .regularExpression) != nil { return "" }
        return model
    }

    func selectAIProvider(_ provider: String) {
        let old = aiProvider ?? "claude"
        guard old != provider else { return }
        let legacy = aiModel == "claude-sonnet-4-6" ? nil : aiModel
        let strong = aiModelStrong?.isEmpty == false ? aiModelStrong : legacy
        let currentModels = [
            "light": Self.migratedModel(aiModelLight, provider: old),
            "strong": Self.migratedModel(strong, provider: old)
        ]
        var edits = editedProviderBuckets[old]?["models"] as? [String: Any] ?? [:]
        for tier in editedModelTiers { edits[tier] = currentModels[tier] }
        if !edits.isEmpty { editedProviderBuckets[old] = ["models": edits] }
        var cached = providerBuckets[old] ?? [:]
        cached["models"] = currentModels
        providerBuckets[old] = cached
        aiProvider = provider
        providerConnection.invalidate()
        let models = providerBuckets[provider]?["models"] as? [String: Any] ?? [:]
        aiModelLight = models["light"] as? String
        aiModelStrong = models["strong"] as? String
        aiModel = nil
        editedModelTiers = []
    }

    /// The Settings picker changes the pair together. The lower-level selector
    /// retains validation semantics for callers editing only ai.provider.
    func selectPreferredProvider(_ provider: String) {
        selectAIProvider(provider)
        // Before the catalog is read nothing is known about the pair, and Go
        // refuses to load a file whose enabled fallback is not a pair: the
        // reserve is turned off until the owner picks it again.
        guard catalog.isLoaded else {
            aiFallbackEnabled = false
            if aiFallbackProvider == provider { aiFallbackProvider = nil }
            return
        }
        if let peer = catalog.reservePeer(of: provider) {
            if aiFallbackProvider != nil { aiFallbackProvider = peer }
        } else {
            aiFallbackEnabled = false
            aiFallbackProvider = nil
        }
    }

    /// The reserve the preferred provider pairs with (the catalog's
    /// `reserve_peer`); nil when it pairs with nothing or the catalog is not
    /// read yet — Settings then hides the reserve.
    var reservePeer: String? { catalog.reservePeer(of: aiProvider ?? "claude") }

    var connectionConfigPath: String { configPath }
    func refreshProviderHealth() async {
        await providerHealth.refresh {
            guard let runner = ProcessCLIRunner.makeDefault() else { throw CLIRunnerError.binaryNotFound }
            let data = try await runner.run(args: ["--config", configPath, "ai", "routing-status", "--check-again"], timeout: 5)
            return try ChatRoutingStatus.parse(data)
        }
    }

    func reserveModel(_ tier: String) -> String? {
        guard let id = aiFallbackProvider ?? reservePeer else { return nil }
        return (providerBuckets[id]?["models"] as? [String: Any])?[tier] as? String
    }

    func setReserveModel(_ tier: String, value: String?) {
        guard let id = aiFallbackProvider else { return }
        var bucket = providerBuckets[id] ?? [:]
        var models = bucket["models"] as? [String: Any] ?? [:]
        models[tier] = value ?? ""
        bucket["models"] = models
        providerBuckets[id] = bucket
        var edits = editedProviderBuckets[id]?["models"] as? [String: Any] ?? [:]
        edits[tier] = value ?? ""
        editedProviderBuckets[id] = ["models": edits]
        providerConnection.invalidate()
    }

    private func captureLegacyModels(
        _ ai: [String: Any], original: String, selected: String, buckets: inout [String: [String: Any]]
    ) {
        guard original != selected || !editedProviderBuckets.isEmpty,
              buckets[original] == nil else { return }
        let legacy = ai["models"] as? [String: Any] ?? [:]
        let model = ai["model"] as? String
        let fallback = model == "claude-sonnet-4-6" ? nil : model
        let strong = legacy["strong"] as? String
        buckets[original] = ["models": [
            "light": Self.migratedModel(legacy["light"] as? String, provider: original),
            "strong": Self.migratedModel(strong?.isEmpty == false ? strong : fallback, provider: original)
        ]]
    }

    private func loadCLIPaths(_ yaml: [String: Any]) {
        claudePath = yaml["claude_path"] as? String
        codexPath = yaml["codex_path"] as? String
        workbenchDefaultAgent = Self.agent(fromYAML: yaml)
    }

    private func resetProviderOperations() {
        providerConnection.invalidate()
        providerHealth.invalidate()
        aiFallbackEnabled = false
        aiFallbackProvider = nil
        loadedFallbackEnabled = false
        loadedFallbackProvider = nil
    }

    private func loadFallback(_ ai: [String: Any]) {
        aiFallbackEnabled = (ai["fallback"] as? [String: Any])?["enabled"] as? Bool ?? false
        aiFallbackProvider = (ai["fallback"] as? [String: Any])?["provider"] as? String
        loadedFallbackEnabled = aiFallbackEnabled
        loadedFallbackProvider = aiFallbackProvider
    }

    private func applyFallback(to ai: inout [String: Any]) {
        if aiFallbackEnabled != loadedFallbackEnabled || aiFallbackProvider != loadedFallbackProvider {
            var fallback = ai["fallback"] as? [String: Any] ?? [:]
            fallback["enabled"] = aiFallbackEnabled
            fallback["provider"] = aiFallbackProvider ?? ""
            ai["fallback"] = fallback
        }
    }

    /// The provider and the reserve pair against the catalog's rows. With no
    /// catalog read yet the pair cannot be confirmed, so an enabled fallback
    /// is refused (Go refuses to load a file whose fallback is not a pair).
    private func validateAISelection(_ selected: String, ai: [String: Any]) throws {
        let fallback = ai["fallback"] as? [String: Any] ?? [:]
        let reserve = fallback["provider"] as? String ?? ""
        let enabled = fallback["enabled"] as? Bool == true
        guard catalog.isLoaded else {
            if !reserve.isEmpty && reserve == selected {
                throw ConfigUnreadableError(reason: "Reserve must be a different provider")
            }
            // Only an edit to the pair is refused: a save of other settings
            // keeps the file's fallback as Go last loaded it.
            let pairEdited = aiFallbackEnabled != loadedFallbackEnabled || aiFallbackProvider != loadedFallbackProvider
                || editableFields["_aiProvider"] != loadedFields["_aiProvider"]
            if enabled && pairEdited {
                throw ConfigUnreadableError(reason: "Provider details are still loading; turn the reserve on again once they load")
            }
            return
        }
        guard catalog.provider(selected) != nil else {
            throw ConfigUnreadableError(reason: "Unknown AI provider")
        }
        if !reserve.isEmpty && (catalog.reservePeer(of: reserve) == nil || reserve == selected) {
            throw ConfigUnreadableError(reason: "Reserve must be a different provider that has a reserve pair")
        }
        if enabled && (reserve.isEmpty || catalog.reservePeer(of: selected) != reserve) {
            throw ConfigUnreadableError(reason: "Enabled fallback requires the preferred provider's reserve pair")
        }
    }

    /// The AI section to update, under its existing key whatever its case
    /// (`AI:` hand-edited): a second lowercase `ai` map would shadow the
    /// owner's background_runs. A section that is ambiguous or not a mapping
    /// throws, so save() refuses rather than overwrite it.
    private static func aiSectionForWrite(_ yaml: [String: Any]) throws -> (key: String, section: [String: Any]) {
        let key = try foldKey(yaml, "ai") ?? "ai"
        let value = yaml[key]
        if value == nil || value is NSNull { return (key, [:]) }
        guard let section = value as? [String: Any] else {
            throw ConfigUnreadableError(reason: "\(key) is not a mapping")
        }
        return (key, section)
    }

    private func applyAISection(to yaml: inout [String: Any]) throws {
        let (aiKey, section) = try Self.aiSectionForWrite(yaml)
        var ai = section
        var buckets = ai["providers"] as? [String: [String: Any]] ?? [:]
        let selected = aiProvider ?? "claude"
        applyFallback(to: &ai)
        try validateAISelection(selected, ai: ai)
        let original = ai["provider"] as? String ?? "claude"
        captureLegacyModels(ai, original: original, selected: selected, buckets: &buckets)
        for (id, edited) in editedProviderBuckets {
            var bucket = buckets[id] ?? [:]
            var models = bucket["models"] as? [String: Any] ?? [:]
            for (tier, value) in edited["models"] as? [String: Any] ?? [:] { models[tier] = value }
            bucket["models"] = models
            buckets[id] = bucket
        }
        if buckets[selected] != nil || !editedProviderBuckets.isEmpty || original != selected {
            var bucket = buckets[selected] ?? [:]
            var models = bucket["models"] as? [String: Any] ?? [:]
            if modelTierEdited("light") {
                models["light"] = aiModelLight ?? ""
            }
            if modelTierEdited("strong") {
                models["strong"] = aiModelStrong ?? ""
            }
            models["light"] = models["light"] as? String ?? ""
            models["strong"] = models["strong"] as? String ?? ""
            bucket["models"] = models
            buckets[selected] = bucket
            ai["providers"] = buckets
        }
        if buckets[selected] == nil {
            if let val = aiModel, !val.isEmpty { ai["model"] = val } else { ai.removeValue(forKey: "model") }
        }
        if let val = aiWorkers { ai["workers"] = val } else { ai.removeValue(forKey: "workers") }
        if let val = aiProvider, !val.isEmpty { ai["provider"] = val } else { ai.removeValue(forKey: "provider") }
        if let val = aiOllamaURL, !val.isEmpty { ai["ollama_url"] = val } else { ai.removeValue(forKey: "ollama_url") }
        if buckets[selected] == nil {
            var aiModels = (ai["models"] as? [String: Any]) ?? [:]
            if let val = aiModelLight, !val.isEmpty { aiModels["light"] = val } else { aiModels.removeValue(forKey: "light") }
            if let val = aiModelStrong, !val.isEmpty { aiModels["strong"] = val } else { aiModels.removeValue(forKey: "strong") }
            if !aiModels.isEmpty { ai["models"] = aiModels } else { ai.removeValue(forKey: "models") }
        }
        if !ai.isEmpty { yaml[aiKey] = ai } else { yaml.removeValue(forKey: aiKey) }
    }

    /// `workbench.default_agent` straight from the file, off the main actor
    /// (the phone hub's slice reads it while publishing): Claude Code when
    /// the file is missing or unreadable.
    nonisolated static func readWorkbenchDefaultAgent(configPath: String = Constants.configPath) -> AgentKind {
        guard let data = FileManager.default.contents(atPath: configPath),
              let str = String(data: data, encoding: .utf8),
              let yaml = try? Yams.load(yaml: str) as? [String: Any] else { return .claude }
        return agent(fromYAML: yaml)
    }

    /// Go reads the value exactly (no trimming, no case folding).
    nonisolated private static func agent(fromYAML yaml: [String: Any]) -> AgentKind {
        guard let workbench = yaml["workbench"] as? [String: Any],
              let raw = workbench["default_agent"] as? String else { return .claude }
        return AgentKind(rawValue: raw) ?? .claude
    }

    /// `workbench.default_agent`: Claude Code, the default, is written only
    /// over a value already on disk, so a fresh config gains no section.
    /// Other `workbench` keys are kept.
    private func applyWorkbenchSection(to yaml: inout [String: Any]) {
        var workbench = (yaml["workbench"] as? [String: Any]) ?? [:]
        if workbenchDefaultAgent == .claude, workbench["default_agent"] == nil { return }
        workbench["default_agent"] = workbenchDefaultAgent.rawValue
        yaml["workbench"] = workbench
    }

    /// A built-in card's When field was refused: an unknown key or a value
    /// the key cannot hold.
    struct BuiltinParameterError: LocalizedError {
        let key: String
        var errorDescription: String? { "This setting can't be saved here: \(key)" }
    }

    /// A built-in card's When **Save** (`show`'s `builtin.parameters[].key`,
    /// twin: Go `builtin.Param` keys): the only writer of `briefing.hour`,
    /// `day_plan.working_hours_start/end`, `day_plan.max_timeblocks`,
    /// `day_plan.min_backlog/max_backlog` (Morning brief) and
    /// `ideas.mine_interval_hours` (Idea finder).
    /// Re-reads the file and writes just these keys, so nothing else this
    /// instance holds is written. Every value is checked before anything is.
    func saveBuiltinParameters(_ values: [String: String]) throws {
        let yaml = try writeLocked { yaml in
            for (key, value) in values.sorted(by: { $0.key < $1.key }) {
                let (section, field, stored) = try Self.builtinParameter(key: key, value: value)
                var dict = (yaml[section] as? [String: Any]) ?? [:]
                dict[field] = stored
                yaml[section] = dict
            }
            // The backlog's at-least never above its at-most, as the file will hold them.
            let planned = (yaml["day_plan"] as? [String: Any]) ?? [:]
            // Absent keys read as Go's defaults (3 and 8), as `reload()` does.
            if (planned["min_backlog"] as? Int ?? 3) > (planned["max_backlog"] as? Int ?? 8) {
                throw BuiltinParameterError(key: BuiltinAutomationCardModel.minBacklogKey)
            }
        }
        rawYAML = yaml
        if let hour = (yaml["briefing"] as? [String: Any])?["hour"] as? Int { briefingHour = hour }
        let dayPlan = (yaml["day_plan"] as? [String: Any]) ?? [:]
        if let start = dayPlan["working_hours_start"] as? String { workingHoursStart = start }
        if let end = dayPlan["working_hours_end"] as? String { workingHoursEnd = end }
        if let count = dayPlan["max_timeblocks"] as? Int { maxTimeblocks = count }
        if let count = dayPlan["min_backlog"] as? Int { minBacklog = count }
        if let count = dayPlan["max_backlog"] as? Int { maxBacklog = count }
        if let hours = (yaml["ideas"] as? [String: Any])?["mine_interval_hours"] as? Int { ideasMineIntervalHours = hours }
    }

    /// Where a built-in parameter lives in the file and its checked value.
    private static func builtinParameter(key: String, value: String) throws -> (String, String, Any) {
        switch key {
        case "briefing.hour":
            guard let hour = Int(value), (0...23).contains(hour) else { throw BuiltinParameterError(key: key) }
            return ("briefing", "hour", hour)
        case "day_plan.working_hours_start", "day_plan.working_hours_end":
            guard BuiltinAutomationCardModel.isClock(value) else { throw BuiltinParameterError(key: key) }
            return ("day_plan", String(key.dropFirst("day_plan.".count)), value)
        case "day_plan.max_timeblocks", BuiltinAutomationCardModel.minBacklogKey,
             BuiltinAutomationCardModel.maxBacklogKey:
            guard BuiltinAutomationCardModel.isCount(value), let count = Int(value) else {
                throw BuiltinParameterError(key: key)
            }
            return ("day_plan", String(key.dropFirst("day_plan.".count)), count)
        case BuiltinAutomationCardModel.ideasIntervalKey:
            guard BuiltinAutomationCardModel.isInterval(value), let hours = Int(value) else {
                throw BuiltinParameterError(key: key)
            }
            return ("ideas", "mine_interval_hours", hours)
        default:
            throw BuiltinParameterError(key: key)
        }
    }

    /// Re-reads the file inside the config write lock (`ConfigFileLock`),
    /// lets `change` edit it and writes the whole file through
    /// `ConfigFileWriter` (owner-only: it holds tokens). Returns what was
    /// written. Reading inside the lock, not the `rawYAML` snapshot of the
    /// last reload(), keeps the sections another process wrote meanwhile
    /// (`watchtower jira login`, `ai background allow`, …); `rawYAML` is the
    /// fallback only when the file is gone. A file that exists but cannot be
    /// read or parsed throws `ConfigUnreadableError` and is not written: a
    /// snapshot would drop the keys only the file holds.
    private func writeLocked(_ change: (inout [String: Any]) throws -> Void) throws -> [String: Any] {
        var written: [String: Any] = [:]
        try fileAccess.withLock(configPath) { token in
            var yaml = try lockedYAMLOnDisk() ?? rawYAML
            try change(&yaml)
            try fileAccess.write(try Yams.dump(object: yaml, allowUnicode: true), configPath, token)
            written = yaml
        }
        return written
    }

    func save() throws {
        providerConnection.invalidate()
        providerHealth.invalidate()
        var purgeChanged = false
        let yaml = try writeLocked { yaml in
            purgeChanged = try applySettings(to: &yaml)
        }
        routingApplication.saved()

        rawYAML = yaml
        loadFallback((try? Self.aiSection(yaml)) ?? [:])
        adoptBackgroundRuns(.mapping(yaml))
        lastSaveChangedPurge = purgeChanged
        diskPurgeRevokedData = purgeRevokedData
        // Adopt what is on disk now, so a switch the CLI turned on behind this
        // instance also shows as on.
        adoptGoogleSyncSwitches(from: yaml)
        if let ai = try? Self.aiSection(yaml) {
            providerBuckets = ai["providers"] as? [String: [String: Any]] ?? [:]
            loadProviderModels()
        }
        resetModelEditTracking()
    }

    /// Writes this instance's settings into `yaml` (the file as re-read
    /// inside the lock), only the keys Settings owns. Returns whether the
    /// purge setting changed.
    private func applySettings(to yaml: inout [String: Any]) throws -> Bool {
        // `active_workspace` is never written here: the CLI owns it (`auth
        // login`, `config set`) and no Settings control edits it, so the only
        // thing save() could write is the snapshot reload() took — stale after
        // any CLI change, and a nil (service loaded before `auth login` wrote
        // the key) assigned to a dictionary subscript REMOVES the key, which
        // left the daemon unable to start while the Desktop kept working off
        // its first-workspace-dir fallback.

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
        if let val = digestMinMessages { digest["min_messages"] = val } else { digest.removeValue(forKey: "min_messages") }
        if let val = digestLanguage, !val.isEmpty { digest["language"] = val } else { digest.removeValue(forKey: "language") }
        if !digest.isEmpty { yaml["digest"] = digest } else { yaml.removeValue(forKey: "digest") }

        // `briefing.hour`, the day plan's keys and `ideas.mine_interval_hours`
        // are not written here: the Morning brief and Idea finder cards
        // (`saveBuiltinParameters`) are their only writer, and a Settings
        // window's snapshot would revert their saves (C2, C3). Nothing else
        // of `ideas` is written: `enabled` is the Feature Manager's (see the
        // `ideasEnabled` property).

        // AI section
        try applyAISection(to: &yaml)

        // Calendar section
        var calendarDict = (yaml["calendar"] as? [String: Any]) ?? [:]
        if calendarEnabled != diskCalendarEnabled { calendarDict["enabled"] = calendarEnabled }
        calendarDict["sync_days_ahead"] = calendarSyncDaysAhead
        yaml["calendar"] = calendarDict

        // Gmail section
        if gmailEnabled != diskGmailEnabled {
            var gmailDict = (yaml["gmail"] as? [String: Any]) ?? [:]
            gmailDict["enabled"] = gmailEnabled
            yaml["gmail"] = gmailDict
        }

        // Transcripts section
        var transcripts = (yaml["transcripts"] as? [String: Any]) ?? [:]
        transcripts["audio_retention_days"] = transcriptAudioRetentionDays
        yaml["transcripts"] = transcripts

        // Claude path override
        if let val = claudePath, !val.isEmpty { yaml["claude_path"] = val } else { yaml.removeValue(forKey: "claude_path") }

        // Codex path override
        if let val = codexPath, !val.isEmpty { yaml["codex_path"] = val } else { yaml.removeValue(forKey: "codex_path") }

        applyWorkbenchSection(to: &yaml)

        // Privacy section: absent stays absent until the owner sets it.
        let purgeChanged = purgeRevokedData != nil && purgeRevokedData != diskPurgeRevokedData
        if let purgeRevokedData {
            var privacy = (yaml["privacy"] as? [String: Any]) ?? [:]
            privacy["purge_revoked_data"] = purgeRevokedData
            yaml["privacy"] = privacy
        }
        return purgeChanged
    }

    /// An edit made here still waits for `save()`.
    var hasUnsavedEdits: Bool {
        !editedModelTiers.isEmpty || !editedProviderBuckets.isEmpty || editableFields != loadedFields
    }

    /// Re-reads config.yaml when nothing awaits `save()`: the one shared copy
    /// (`AppState.sharedConfig`) catches up with a CLI or editor change each
    /// time Settings or the Connections tab shows, and never drops an edit.
    func reloadUnlessEdited() {
        if !hasUnsavedEdits { reload() }
    }

    /// Bookkeeping, not settings: left out of the edit check.
    private static let nonEditableFields: Set<String> = [
        "configPath", "fileAccess", "routingApplication", "_rawYAML", "_parseError", "_lastSaveChangedPurge",
        "_backgroundRuns", "_backgroundRunsUnreadable", "_savedAIProvider",
        "_diskCalendarEnabled", "_diskGmailEnabled", "_diskPurgeRevokedData", "loadedFields",
        "_providerBuckets", "_editedProviderBuckets", "editedModelTiers",
        "_providerConnection", "_providerHealth", "providerConnection", "providerHealth", "loadedFallbackEnabled", "loadedFallbackProvider"
    ]

    /// Every settings field (the stored properties, by reflection, so a new
    /// one is covered without a list to keep in step), rendered for comparison.
    private var editableFields: [String: String] {
        var fields: [String: String] = [:]
        for child in Mirror(reflecting: self).children {
            guard let label = child.label, !label.hasPrefix("_$"), !Self.nonEditableFields.contains(label) else { continue }
            fields[label] = Self.comparable(child.value)
        }
        return fields
    }

    /// A field's value as text that is equal exactly when the value is: a
    /// dictionary (`jiraFeatures`) by its sorted keys, since two equal
    /// dictionaries may print their keys in different orders.
    private static func comparable(_ value: Any) -> String {
        guard let dict = value as? [String: Any] else { return String(describing: value) }
        return dict.sorted { $0.key < $1.key }.map { "\($0.key):\(String(describing: $0.value))" }.joined(separator: ",")
    }

    /// A Google sync switch differs from what is on disk: the owner flipped
    /// it here and it awaits `save()`.
    var googleSyncSwitchesChanged: Bool {
        calendarEnabled != diskCalendarEnabled || gmailEnabled != diskGmailEnabled
    }

    /// Re-reads `calendar.enabled`/`gmail.enabled` from disk, leaving every
    /// other field (and any unsaved edit in it) alone, unlike `reload()`: a
    /// Google connect turns them on from the CLI (#740) while Settings shows
    /// them. An unreadable file changes nothing.
    func adoptGoogleSyncSwitchesFromDisk() {
        guard let yaml = currentYAMLOnDisk() else { return }
        adoptGoogleSyncSwitches(from: yaml)
    }

    private func adoptGoogleSyncSwitches(from yaml: [String: Any]) {
        diskCalendarEnabled = ((yaml["calendar"] as? [String: Any])?["enabled"] as? Bool) ?? true
        diskGmailEnabled = ((yaml["gmail"] as? [String: Any])?["enabled"] as? Bool) ?? true
        calendarEnabled = diskCalendarEnabled
        gmailEnabled = diskGmailEnabled
        // What came from disk is no edit: only these two fields join the
        // baseline, so an unsaved edit elsewhere still counts.
        let current = editableFields
        for label in ["_calendarEnabled", "_gmailEnabled"] { loadedFields[label] = current[label] }
    }

    /// Load the current on-disk config as a raw YAML dictionary, without
    /// touching any of the published `@Observable` properties; nil when it
    /// is missing or unreadable. (A write re-reads with `lockedYAMLOnDisk`.)
    private func currentYAMLOnDisk() -> [String: Any]? {
        guard let data = try? fileAccess.read(configPath),
              let str = String(data: data, encoding: .utf8),
              let yaml = try? Yams.load(yaml: str) as? [String: Any] else {
            return nil
        }
        return yaml
    }

    /// The file as `writeLocked` re-reads it: nil when there is no file; an
    /// unreadable or unparsable file throws.
    private func lockedYAMLOnDisk() throws -> [String: Any]? {
        let data: Data?
        do { data = try fileAccess.read(configPath) } catch {
            throw ConfigUnreadableError(reason: error.localizedDescription)
        }
        guard let data else { return nil }
        guard let str = String(data: data, encoding: .utf8) else {
            throw ConfigUnreadableError(reason: "not UTF-8 text")
        }
        let loaded: Any?
        do { loaded = try Yams.load(yaml: str) } catch {
            throw ConfigUnreadableError(reason: "invalid YAML")
        }
        guard let loaded else { return [:] }
        guard let yaml = loaded as? [String: Any] else {
            throw ConfigUnreadableError(reason: "not a YAML mapping")
        }
        return yaml
    }

    /// Once disk Save succeeds, acknowledge routing even when an independent
    /// feature/privacy operation fails. Keep that operation's error visible.
    func saveAndApply(extraSave: (() async throws -> Void)? = nil) async throws {
        try save()
        var extraError: (any Error)?
        do { try await extraSave?() } catch { extraError = error }
        await applySavedRouting()
        if let extraError { throw extraError }
    }

    func applySavedRouting() async { await routingApplication.applyLatest() }

    func openInEditor() {
        let url = URL(fileURLWithPath: configPath)
        NSWorkspace.shared.open(url)
    }

    func revealInFinder() {
        let url = URL(fileURLWithPath: configPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// config.yaml is present but cannot be read or parsed.
struct ConfigUnreadableError: LocalizedError {
    let reason: String
    var errorDescription: String? { "config.yaml can't be read (\(reason)) — fix the file, then try again." }
}

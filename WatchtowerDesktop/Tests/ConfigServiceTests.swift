import Foundation
import Testing
import Yams
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
@Suite("ConfigService")
struct ConfigServiceTests {
    /// The fallback pair is the catalog's reserve_peer: the shared catalog
    /// holds the Go-written rows, as after the app's launch read.
    init() { ProviderCatalogFixture.seedShared() }

    @Test("The reserve pair comes from the catalog; a catalog without reserve_peer hides the reserve")
    func testReservePairComesFromCatalog() throws {
        let path = makeTempConfig("ai: {provider: claude, fallback: {enabled: true, provider: codex}}")
        let paired = ConfigService(configPath: path)
        #expect(paired.reservePeer == "codex")
        paired.selectPreferredProvider("codex")
        #expect(paired.aiFallbackProvider == "claude")

        let unpaired = AIModelCatalog(providers: ProviderCatalogFixture.providers().map { row in
            var row = row
            if let caps = row.capabilities {
                row.capabilities = ProviderCapabilities(
                    tools: caps.tools, images: caps.images, pdfs: caps.pdfs, readFolder: caps.readFolder)
            }
            return row
        })
        let service = ConfigService(configPath: makeTempConfig("ai: {provider: claude}"), catalog: unpaired)
        #expect(service.reservePeer == nil)
        #expect(service.reserveModel("strong") == nil)
        service.aiFallbackProvider = "codex"
        service.aiFallbackEnabled = true
        service.selectPreferredProvider("codex")
        #expect(service.aiFallbackProvider == nil)
        #expect(!service.aiFallbackEnabled)
    }

    @Test("Before the catalog is read a provider switch turns the reserve off and an enabled fallback is refused")
    func testUnreadCatalogKeepsGoLoadable() throws {
        let path = makeTempConfig("ai: {provider: claude, fallback: {enabled: true, provider: codex}}")
        let service = ConfigService(configPath: path, catalog: AIModelCatalog())
        service.selectPreferredProvider("codex")
        #expect(!service.aiFallbackEnabled)
        #expect(service.aiFallbackProvider == nil)
        service.aiFallbackProvider = "claude"
        service.aiFallbackEnabled = true
        #expect(throws: (any Error).self) { try service.save() }
    }

    @Test("Reserve starts off and independent models survive switches and Saves", arguments: ["claude", "codex"])
    func reserveBuckets(provider: String) throws {
        let other = provider == "claude" ? "codex" : "claude"
        let path = makeTempConfig("ai: {provider: \(provider), providers: {"
            + "\(provider): {models: {strong: preferred-model}}, \(other): {models: {strong: reserve-model}}}}")
        let service = ConfigService(configPath: path)
        #expect(!service.aiFallbackEnabled)
        #expect(service.reserveModel("strong") == "reserve-model")
        service.aiFallbackProvider = other
        service.setReserveModel("light", value: "reserve-light")
        service.aiFallbackEnabled = true
        try service.save()
        let saved = ConfigService(configPath: path)
        #expect(saved.aiFallbackEnabled)
        #expect(saved.aiModelStrong == "preferred-model")
        #expect(saved.reserveModel("light") == "reserve-light")
        saved.selectPreferredProvider(other)
        #expect(saved.aiModelStrong == "reserve-model")
        #expect(saved.reserveModel("strong") == "preferred-model")
        try saved.save()
        saved.selectPreferredProvider("ollama")
        #expect(!saved.aiFallbackEnabled)
        try saved.save()
        saved.selectPreferredProvider(provider)
        #expect(saved.aiModelStrong == "preferred-model")
    }

    @Test("Editing only reserve models preserves legacy preferred overrides")
    func reserveEditPreservesLegacyPreferred() throws {
        let path = makeTempConfig("ai: {provider: claude, model: opus, models: {light: haiku}}")
        let service = ConfigService(configPath: path)
        service.aiFallbackProvider = "codex"
        service.setReserveModel("strong", value: "reserve-model")
        try service.save()
        let saved = ConfigService(configPath: path)
        #expect(saved.aiModelStrong == "opus")
        #expect(saved.aiModelLight == "haiku")
        #expect(saved.reserveModel("strong") == "reserve-model")
    }

    @Test("Unedited reserve keeps newer CLI edits even after a previous Save")
    func reserveExternalWinner() throws {
        let path = makeTempConfig("ai: {provider: claude}")
        let service = ConfigService(configPath: path)
        service.aiFallbackProvider = "codex"
        service.aiFallbackEnabled = true
        try service.save()
        var yaml = try #require(try Yams.load(yaml: String(contentsOfFile: path)) as? [String: Any])
        var ai = try #require(yaml["ai"] as? [String: Any])
        ai["fallback"] = ["enabled": false, "provider": "codex"]
        yaml["ai"] = ai
        try Yams.dump(object: yaml).write(toFile: path, atomically: true, encoding: .utf8)
        service.syncInterval = "2m"
        try service.save()
        #expect(!ConfigService(configPath: path).aiFallbackEnabled)
    }

    @Test("Migrated model edits update authoritative provider bucket")
    func migratedModelEdits() throws {
        let path = makeTempConfig("ai: {provider: claude, model: sonnet, providers: {claude: {models: {strong: opus}}, codex: {}}}")
        let service = ConfigService(configPath: path)
        #expect(service.aiModelStrong == "opus")
        service.aiModelStrong = "sonnet"
        try service.save()
        let reloaded = ConfigService(configPath: path)
        #expect(reloaded.aiModelStrong == "sonnet")
        reloaded.selectAIProvider("codex")
        #expect(reloaded.aiModelStrong == nil)
        reloaded.selectAIProvider("claude")
        #expect(reloaded.aiModelStrong == "sonnet")
    }

    @Test("Legacy provider switches preserve original models")
    func legacyProviderSwitchRestoresModels() throws {
        let path = makeTempConfig("ai: {provider: claude, model: sonnet}")
        let service = ConfigService(configPath: path)
        service.selectAIProvider("codex")
        #expect(service.aiModelStrong == nil)
        try service.save()
        let reloaded = ConfigService(configPath: path)
        reloaded.selectAIProvider("claude")
        #expect(reloaded.aiModelStrong == "sonnet")
    }

    @Test("Direct provider assignment captures legacy and destination Default")
    func directLegacyProviderSwitch() throws {
        let path = makeTempConfig("ai: {provider: claude, model: sonnet}")
        let service = ConfigService(configPath: path)
        service.aiProvider = "codex"
        service.aiModel = nil
        try service.save()
        let reloaded = ConfigService(configPath: path)
        #expect(reloaded.aiModelStrong?.isEmpty == true)
        reloaded.selectAIProvider("claude")
        #expect(reloaded.aiModelStrong == "sonnet")
    }

    @Test("Retired legacy setup model remains Default on provider switch")
    func retiredLegacyProviderSwitch() throws {
        let path = makeTempConfig("ai: {provider: claude, model: claude-sonnet-4-6, models: {strong: ''}}")
        let service = ConfigService(configPath: path)
        service.selectAIProvider("codex")
        service.selectAIProvider("claude")
        #expect(service.aiModelStrong?.isEmpty == true)
    }

    @Test("Invalid enabled reserve pair is refused before saving")
    func invalidReservePairPreservesFile() throws {
        let cases = [
            ("codex", "Reserve must be a different provider that has a reserve pair"),
            ("ollama", "Enabled fallback requires the preferred provider's reserve pair"),
            ("unknown", "Unknown AI provider")
        ]
        for (destination, reason) in cases {
            let path = makeTempConfig("ai: {provider: claude, fallback: {enabled: true, provider: codex}}")
            let original = try String(contentsOfFile: path, encoding: .utf8)
            let service = ConfigService(configPath: path)
            service.selectAIProvider(destination)
            do {
                try service.save()
                Issue.record("An invalid reserve pair was saved")
            } catch {
                #expect(error.localizedDescription == "config.yaml can't be read (\(reason)) — fix the file, then try again.")
            }
            #expect(try String(contentsOfFile: path, encoding: .utf8) == original)
        }
    }

    @Test("Bucket saves merge unknown fields and fresh reserve changes")
    func bucketSavePreservesFreshFields() throws {
        let path = makeTempConfig("ai: {provider: claude, providers: {claude: {models: {strong: opus}}}}")
        let service = ConfigService(configPath: path)
        service.aiModelStrong = "sonnet"
        try "ai: {provider: claude, providers: {claude: {extra: keep, models: {strong: opus, custom: keep}}, codex: {models: {strong: fresh}}}}"
            .write(toFile: path, atomically: true, encoding: .utf8)
        try service.save()
        let yaml = try Yams.load(yaml: String(contentsOfFile: path, encoding: .utf8)) as? [String: Any]
        let ai = yaml?["ai"] as? [String: Any]
        let buckets = ai?["providers"] as? [String: [String: Any]]
        #expect(buckets?["claude"]?["extra"] as? String == "keep")
        let models = buckets?["claude"]?["models"] as? [String: String]
        #expect(models?["custom"] == "keep")
        let reserve = buckets?["codex"]?["models"] as? [String: String]
        #expect(reserve?["strong"] == "fresh")
    }

    @Test("Save adopts fresh CLI buckets without stale model writes")
    func staleLegacySaveAdoptsFreshBuckets() throws {
        for edit in ["none", "sync", "calendar", "workers"] {
            let path = makeTempConfig("ai: {provider: claude, model: sonnet}")
            let service = ConfigService(configPath: path)
            if edit == "sync" { service.syncWorkers = 3 }
            if edit == "calendar" { service.calendarSyncDaysAhead = 9 }
            if edit == "workers" { service.aiWorkers = 2 }
            try "ai: {provider: claude, model: sonnet, workers: 2, providers: {claude: {models: {light: fresh-light, strong: fresh-strong}}}}"
                .write(toFile: path, atomically: true, encoding: .utf8)
            try service.save()
            let reloaded = ConfigService(configPath: path)
            #expect(reloaded.aiModelStrong == "fresh-strong", "edit: \(edit)")
            #expect(reloaded.aiModelLight == "fresh-light")
            #expect(service.aiModelStrong == "fresh-strong", "saved service must adopt fresh models")
            service.aiWorkers = 4
            try service.save()
            #expect(ConfigService(configPath: path).aiModelStrong == "fresh-strong")
        }
    }

    @Test("Intentional strong edit and clear override fresh CLI buckets")
    func staleLegacyModelEditWins() throws {
        for strong in ["opus", ""] {
            let path = makeTempConfig("ai: {provider: claude, model: sonnet}")
            let service = ConfigService(configPath: path)
            service.aiModelStrong = strong.isEmpty ? nil : strong
            #expect(service.hasUnsavedEdits, "explicit clear must remain saveable")
            try "ai: {provider: claude, providers: {claude: {models: {strong: fresh-strong, light: fresh-light}}}}"
                .write(toFile: path, atomically: true, encoding: .utf8)
            try service.save()
            let reloaded = ConfigService(configPath: path)
            #expect(reloaded.aiModelStrong == strong)
            #expect(!service.hasUnsavedEdits)
            #expect(reloaded.aiModelLight == "fresh-light")
        }
    }

    @Test("Provider choice preserves fresh profiles except explicitly edited tiers")
    func providerChoicePreservesFreshProfiles() throws {
        let explicitModels: [String?] = [nil, "own-model"]
        for explicit in explicitModels {
            let path = makeTempConfig("ai: {provider: claude, providers: {claude: {models: {strong: old-claude}}, codex: {}}}")
            let service = ConfigService(configPath: path)
            service.selectAIProvider("codex")
            if let explicit { service.aiModelStrong = explicit }
            let fresh = "ai: {provider: claude, providers: {claude: {models: {strong: fresh-claude}}, "
                + "codex: {models: {strong: fresh-codex, light: fresh-light}}}}"
            try fresh.write(toFile: path, atomically: true, encoding: .utf8)
            try service.save()
            let reloaded = ConfigService(configPath: path)
            #expect(reloaded.aiProvider == "codex")
            #expect(reloaded.aiModelStrong == (explicit ?? "fresh-codex"))
            #expect(reloaded.aiModelLight == "fresh-light")
            reloaded.selectAIProvider("claude")
            #expect(reloaded.aiModelStrong == "fresh-claude")
        }
    }

    @Test("Unsaved model edits survive switching to another provider")
    func pendingModelsSurviveProviderChoice() throws {
        let path = makeTempConfig("ai: {provider: claude, model: sonnet, models: {light: custom-light}}")
        let service = ConfigService(configPath: path)
        service.aiModelStrong = "opus"
        service.selectAIProvider("codex")
        try service.save()
        let reloaded = ConfigService(configPath: path)
        reloaded.selectAIProvider("claude")
        #expect(reloaded.aiModelStrong == "opus")
        #expect(reloaded.aiModelLight == "custom-light")
    }

    @Test("Reload discards pending profile edits when the AI section was removed")
    func reloadDiscardsRemovedProfileEdits() throws {
        let path = makeTempConfig("ai: {provider: claude, model: sonnet}")
        let service = ConfigService(configPath: path)
        service.aiModelStrong = "opus"
        service.selectAIProvider("codex")
        #expect(service.hasUnsavedEdits)
        try "sync: {poll_interval: 5m}".write(toFile: path, atomically: true, encoding: .utf8)
        service.reload()
        #expect(service.parseError == nil)
        #expect(!service.hasUnsavedEdits)
    }

    private func makeTempConfig(_ yaml: String) -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchtower-config-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("config.yaml").path
        try? yaml.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test("Load parses scalar fields")
    func loadScalars() {
        let path = makeTempConfig("""
        active_workspace: dev
        claude_path: /opt/claude
        codex_path: /opt/codex
        """)
        let svc = ConfigService(configPath: path)
        #expect(svc.activeWorkspace == "dev")
        #expect(svc.claudePath == "/opt/claude")
        #expect(svc.codexPath == "/opt/codex")
        #expect(svc.parseError == nil)
    }

    /// The service can load before `auth login` writes active_workspace
    /// (Settings opened first, or the Slack step skipped). Save must then
    /// leave the key the CLI wrote in the meantime alone — assigning a nil
    /// to the YAML dictionary deletes it, and a config without
    /// active_workspace cannot start the daemon.
    @Test("Save keeps an active_workspace written after load")
    func saveKeepsWorkspaceWrittenAfterLoad() throws {
        let path = makeTempConfig("""
        sync:
          workers: 2
        """)
        let svc = ConfigService(configPath: path)
        #expect(svc.activeWorkspace == nil)

        try """
        active_workspace: zenith
        sync:
          workers: 2
        """.write(toFile: path, atomically: true, encoding: .utf8)

        try svc.save()

        let saved = try Yams.load(yaml: String(contentsOfFile: path, encoding: .utf8)) as? [String: Any]
        #expect(saved?["active_workspace"] as? String == "zenith")
    }

    /// The CLI owns `active_workspace`; the Desktop only displays it. A value
    /// the CLI changed after this service loaded must survive Save — the
    /// in-memory snapshot is stale, not authoritative.
    @Test("Save never overwrites an active_workspace the CLI changed after load")
    func saveKeepsWorkspaceChangedAfterLoad() throws {
        let path = makeTempConfig("""
        active_workspace: zenith
        sync:
          workers: 2
        """)
        let svc = ConfigService(configPath: path)
        #expect(svc.activeWorkspace == "zenith")

        try """
        active_workspace: acme
        sync:
          workers: 2
        """.write(toFile: path, atomically: true, encoding: .utf8)

        try svc.save()

        let saved = try Yams.load(yaml: String(contentsOfFile: path, encoding: .utf8)) as? [String: Any]
        #expect(saved?["active_workspace"] as? String == "acme")
    }

    @Test("Load parses sync section")
    func loadSync() {
        let path = makeTempConfig("""
        sync:
          poll_interval: 5m
          workers: 4
          sync_threads: false
          initial_history_days: 14
        """)
        let svc = ConfigService(configPath: path)
        #expect(svc.syncInterval == "5m")
        #expect(svc.syncWorkers == 4)
        #expect(svc.syncThreads == false)
        #expect(svc.initialHistoryDays == 14)
    }

    @Test("Load parses calendar history days with a 30-day fallback")
    func loadCalendarHistoryDays() {
        let path = makeTempConfig("""
        calendar:
          enabled: true
          sync_days_ahead: 7
          history_days: 21
        """)
        let svc = ConfigService(configPath: path)
        #expect(svc.calendarHistoryDays == 21)

        let fallbackPath = makeTempConfig("""
        calendar:
          enabled: true
        """)
        let fallback = ConfigService(configPath: fallbackPath)
        #expect(fallback.calendarHistoryDays == 30)
    }

    @Test("Load applies defaults for missing day_plan keys")
    func loadDayPlanDefaults() {
        let path = makeTempConfig("active_workspace: x\n")
        let svc = ConfigService(configPath: path)
        #expect(svc.dayPlanEnabled == true)
        #expect(svc.workingHoursStart == "09:00")
        #expect(svc.workingHoursEnd == "19:00")
        #expect(svc.maxTimeblocks == 3)
        #expect(svc.minBacklog == 3)
        #expect(svc.maxBacklog == 8)
    }

    @Test("Load applies defaults for missing ideas keys")
    func loadIdeasDefaults() {
        let path = makeTempConfig("active_workspace: x\n")
        let svc = ConfigService(configPath: path)
        #expect(svc.ideasEnabled == true)
        #expect(svc.ideasMineIntervalHours == 6)
    }

    @Test("Load parses ideas section")
    func loadIdeas() {
        let path = makeTempConfig("""
        ideas:
          enabled: false
          mine_interval_hours: 12
        """)
        let svc = ConfigService(configPath: path)
        #expect(svc.ideasEnabled == false)
        #expect(svc.ideasMineIntervalHours == 12)
    }

    @Test("AI tier models and ollama URL round-trip")
    func aiModelsRoundTrip() throws {
        let path = makeTempConfig("""
        ai:
          provider: ollama
          model: legacy-model
          ollama_url: http://box:11434
          models:
            light: qwen3:8b
            strong: llama4:70b
        """)
        let svc = ConfigService(configPath: path)
        #expect(svc.aiProvider == "ollama")
        #expect(svc.aiModel == "legacy-model")
        #expect(svc.aiOllamaURL == "http://box:11434")
        #expect(svc.aiModelLight == "qwen3:8b")
        #expect(svc.aiModelStrong == "llama4:70b")

        svc.aiModelLight = "gemma4:31b"
        svc.aiModelStrong = nil
        try svc.save()

        let svc2 = ConfigService(configPath: path)
        #expect(svc2.aiModelLight == "gemma4:31b")
        #expect(svc2.aiModelStrong == nil, "cleared tier override must be removed from yaml")
        #expect(svc2.aiOllamaURL == "http://box:11434", "untouched keys survive the save merge")
        #expect(svc2.aiModel == "legacy-model", "legacy ai.model is preserved, not rewritten")
    }

    @Test("Save does not invent ai.models on a config that has none")
    func saveNoEmptyAIModels() throws {
        let path = makeTempConfig("""
        ai:
          provider: claude
        """)
        let svc = ConfigService(configPath: path)
        try svc.save()

        let yaml = try Yams.load(yaml: String(contentsOfFile: path, encoding: .utf8)) as? [String: Any]
        let ai = yaml?["ai"] as? [String: Any]
        #expect(ai?["models"] == nil, "no empty models: block may appear")
        #expect(ai?["ollama_url"] == nil)
    }

    @Test("A built-in card's When fields save to their config keys; unknown keys and bad values are refused")
    func builtinParametersSave() throws {
        let path = makeTempConfig("""
        active_workspace: keep-me
        briefing:
          hour: 8
        """)
        let svc = ConfigService(configPath: path)
        try svc.saveBuiltinParameters([
            "briefing.hour": "9", "day_plan.working_hours_start": "08:30", "day_plan.working_hours_end": "17:00"
        ])
        #expect(svc.briefingHour == 9)
        #expect(throws: ConfigService.BuiltinParameterError.self) { try svc.saveBuiltinParameters(["briefing.hour": "24"]) }
        #expect(throws: ConfigService.BuiltinParameterError.self) {
            try svc.saveBuiltinParameters(["day_plan.working_hours_end": "7pm"])
        }
        #expect(throws: ConfigService.BuiltinParameterError.self, "on/off is the feature manager's") {
            try svc.saveBuiltinParameters(["ideas.enabled": "true"])
        }

        let svc2 = ConfigService(configPath: path)
        #expect(svc2.briefingHour == 9)
        #expect(svc2.workingHoursStart == "08:30")
        #expect(svc2.workingHoursEnd == "17:00")
        #expect(svc2.activeWorkspace == "keep-me")
    }

    @Test("The card's count fields save as integers; a backlog at-least above its at-most is refused")
    func builtinCountParametersSave() throws {
        let path = makeTempConfig("day_plan:\n  max_backlog: 6\n")
        let svc = ConfigService(configPath: path)
        try svc.saveBuiltinParameters([
            "day_plan.max_timeblocks": "2", "day_plan.min_backlog": "4", "day_plan.max_backlog": "7"
        ])
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        let dayPlan = (try Yams.load(yaml: raw) as? [String: Any])?["day_plan"] as? [String: Any]
        #expect(dayPlan?["max_timeblocks"] as? Int == 2, "an integer, not text; got: \(raw)")
        #expect(dayPlan?["min_backlog"] as? Int == 4)
        #expect(dayPlan?["max_backlog"] as? Int == 7)
        #expect(svc.maxTimeblocks == 2)

        #expect(throws: ConfigService.BuiltinParameterError.self) {
            try svc.saveBuiltinParameters(["day_plan.min_backlog": "8"])
        }
        #expect(throws: ConfigService.BuiltinParameterError.self) {
            try svc.saveBuiltinParameters(["day_plan.max_timeblocks": "-1"])
        }
        let reloaded = ConfigService(configPath: path)
        #expect(reloaded.minBacklog == 4, "a refused save writes nothing")
        #expect(reloaded.maxTimeblocks == 2)
    }

    /// Settings keeps one ConfigService for the window's life: its Save must
    /// not put back the hour and working hours the card saved meanwhile.
    @Test("A Settings save after a card save keeps the card's When values")
    func settingsSaveKeepsCardValues() throws {
        let path = makeTempConfig("""
        briefing:
          hour: 8
        day_plan:
          working_hours_start: "09:00"
          max_timeblocks: 4
        """)
        let settings = ConfigService(configPath: path)
        try ConfigService(configPath: path).saveBuiltinParameters([
            "briefing.hour": "10", "day_plan.working_hours_start": "07:45"
        ])
        settings.digestMinMessages = 7
        try settings.save()

        let reloaded = ConfigService(configPath: path)
        #expect(reloaded.briefingHour == 10)
        #expect(reloaded.workingHoursStart == "07:45")
        #expect(reloaded.maxTimeblocks == 4)
        #expect(reloaded.digestMinMessages == 7)
    }

    /// The Idea finder card saves the interval through a fresh instance; the
    /// Settings window's long-lived one must not put the old value back (C3).
    @Test("A Settings save after Idea finder's card save keeps the card's interval")
    func settingsSaveKeepsIdeasInterval() throws {
        let path = makeTempConfig("""
        ideas:
          mine_interval_hours: 6
        """)
        let settings = ConfigService(configPath: path)
        try ConfigService(configPath: path).saveBuiltinParameters(["ideas.mine_interval_hours": "9"])
        settings.digestMinMessages = 7
        try settings.save()

        let reloaded = ConfigService(configPath: path)
        #expect(reloaded.ideasMineIntervalHours == 9)
        #expect(reloaded.digestMinMessages == 7)
    }

    @Test("Save writes neither ideas.enabled nor the Idea finder interval, and preserves unrelated keys")
    func saveIdeasRoundTrip() throws {
        let path = makeTempConfig("""
        active_workspace: keep-me
        ideas:
          enabled: false
          mine_interval_hours: 12
        """)
        let svc = ConfigService(configPath: path)
        #expect(svc.ideasEnabled == false)
        #expect(svc.ideasMineIntervalHours == 12)

        // The on/off property is display-only: flipping it and saving must
        // not write it back — the Feature Manager CLI owns that key.
        svc.ideasEnabled = true
        svc.ideasMineIntervalHours = 24
        try svc.save()

        let svc2 = ConfigService(configPath: path)
        #expect(svc2.ideasMineIntervalHours == 12, "the interval's only writer is Idea finder's card")
        #expect(svc2.ideasEnabled == false, "on-disk ideas.enabled must survive a save that changed another field")
        #expect(svc2.activeWorkspace == "keep-me", "unrelated keys must survive the save merge")
    }

    /// The three feature on/off keys have exactly one writer — the
    /// `watchtower features enable|disable` CLI. `ConfigService.save()`
    /// parses them (other views read the properties) but must never write
    /// them back, or an ordinary Settings Save races the CLI and silently
    /// reverts whatever the Feature Manager just applied.
    @Test("Save leaves the three Feature Manager on/off keys exactly as the CLI wrote them")
    func saveNeverWritesFeatureOnOffKeys() throws {
        let path = makeTempConfig("""
        active_workspace: keep-me
        digest:
          enabled: false
          language: English
        ideas:
          enabled: false
          mine_interval_hours: 12
        day_plan:
          enabled: false
          hour: 7
        """)
        let svc = ConfigService(configPath: path)

        // Flip all three display-only properties AND change one real tuning
        // field, so the save definitely rewrites every section involved.
        svc.digestEnabled = true
        svc.ideasEnabled = true
        svc.dayPlanEnabled = true
        svc.briefingHour = 11
        try svc.save()

        let raw = try String(contentsOfFile: path, encoding: .utf8)
        let yaml = try Yams.load(yaml: raw) as? [String: Any]
        let digest = yaml?["digest"] as? [String: Any]
        let ideas = yaml?["ideas"] as? [String: Any]
        let dayPlan = yaml?["day_plan"] as? [String: Any]

        #expect(digest?["enabled"] as? Bool == false, "digest.enabled must pass through untouched; got: \(raw)")
        #expect(ideas?["enabled"] as? Bool == false, "ideas.enabled must pass through untouched; got: \(raw)")
        #expect(dayPlan?["enabled"] as? Bool == false, "day_plan.enabled must pass through untouched; got: \(raw)")

        // Tuning keys in the same sections still save normally.
        #expect(digest?["language"] as? String == "English")
        #expect(dayPlan?["hour"] as? Int == 7)
        #expect(ideas?["mine_interval_hours"] as? Int == 12)
    }

    /// `digestEnabled` defaults to `false` when the config has no digest
    /// section, so writing it unconditionally used to make a plain Save on a
    /// fresh install materialize `digest.enabled: false` — precisely the
    /// legacy "all AI off" signature the Go migration looks for.
    @Test("Save does not invent a digest section on a config that has none")
    func saveDoesNotInventDigestSection() throws {
        let path = makeTempConfig("active_workspace: x\n")
        let svc = ConfigService(configPath: path)
        svc.briefingHour = 9
        try svc.save()

        let raw = try String(contentsOfFile: path, encoding: .utf8)
        let yaml = try Yams.load(yaml: raw) as? [String: Any]
        #expect(yaml?.keys.contains("digest") == false, "an absent digest section must stay absent; got: \(raw)")
        #expect(
            (yaml?["ideas"] as? [String: Any])?.keys.contains("enabled") != true,
            "ideas.enabled must not be created by a save (the save writes no ideas key at all); got: \(raw)"
        )
        #expect(
            (yaml?["day_plan"] as? [String: Any])?.keys.contains("enabled") != true,
            "day_plan.enabled must not be created by a save; got: \(raw)"
        )
    }

    @Test("Load parses ai and digest sections")
    func loadAIDigest() {
        let path = makeTempConfig("""
        ai:
          model: claude-opus
          provider: claude
          workers: 2
        digest:
          enabled: true
          model: haiku
          min_messages: 3
          language: English
        briefing:
          hour: 9
        """)
        let svc = ConfigService(configPath: path)
        #expect(svc.aiModel == "claude-opus")
        #expect(svc.aiProvider == "claude")
        #expect(svc.aiWorkers == 2)
        #expect(svc.digestEnabled == true)
        #expect(svc.digestMinMessages == 3)
        #expect(svc.digestLanguage == "English")
        #expect(svc.briefingHour == 9)
    }

    /// Go's defaults since 2026-10-14 (#757): an absent `enabled` key, or a
    /// missing section, reads as on; an explicit false is kept.
    @Test("Absent calendar.enabled and gmail.enabled read as Go's true")
    func loadCalendarAndGmailEnabledDefaults() {
        let absent = ConfigService(configPath: makeTempConfig("active_workspace: x\n"))
        #expect(absent.calendarEnabled == true)
        #expect(absent.gmailEnabled == true)

        let noKey = ConfigService(configPath: makeTempConfig("""
        calendar:
          sync_days_ahead: 5
        gmail: {}
        """))
        #expect(noKey.calendarEnabled == true)
        #expect(noKey.gmailEnabled == true)

        let off = ConfigService(configPath: makeTempConfig("""
        calendar:
          enabled: false
        gmail:
          enabled: false
        """))
        #expect(off.calendarEnabled == false)
        #expect(off.gmailEnabled == false)
    }

    @Test("Load parses calendar settings")
    func loadCalendar() {
        let path = makeTempConfig("""
        calendar:
          enabled: true
          sync_days_ahead: 5
        """)
        let svc = ConfigService(configPath: path)
        #expect(svc.calendarEnabled == true)
        #expect(svc.calendarSyncDaysAhead == 5)
    }

    /// Go's `DefaultCalendarSyncDaysAhead` is 7. Swift used to default an
    /// absent key to 2 and `save()` always writes it, so toggling "Enable
    /// calendar sync" on an install without the key silently shrank the
    /// daemon's horizon to 2 days.
    @Test("An absent calendar.sync_days_ahead defaults to Go's 7 and saves as 7")
    func calendarSyncDaysAheadDefaultMatchesGo() throws {
        for yaml in ["calendar:\n  enabled: false\n", "active_workspace: acme\n"] {
            let path = makeTempConfig(yaml)
            let svc = ConfigService(configPath: path)
            #expect(svc.calendarSyncDaysAhead == 7)

            svc.calendarEnabled = true
            try svc.save()
            let saved = try Yams.load(yaml: String(contentsOfFile: path, encoding: .utf8)) as? [String: Any]
            let calendar = saved?["calendar"] as? [String: Any]
            #expect(calendar?["sync_days_ahead"] as? Int == 7)
        }
    }

    /// #740: `google add` turns `calendar.enabled`/`gmail.enabled` on while a
    /// Settings window's ConfigService, loaded before the connect, still holds
    /// `false`. Its next unrelated Save must not switch the sync back off.
    @Test("Save keeps sync switches the CLI turned on after load")
    func saveKeepsSyncSwitchesTurnedOnAfterLoad() throws {
        let path = makeTempConfig("calendar:\n  enabled: false\ngmail:\n  enabled: false\n")
        let stale = ConfigService(configPath: path)
        #expect(stale.calendarEnabled == false)

        // The CLI's connect writes the switches behind the loaded instance.
        try "calendar:\n  enabled: true\ngmail:\n  enabled: true\n"
            .write(toFile: path, atomically: true, encoding: .utf8)

        stale.transcriptAudioRetentionDays = 10
        try stale.save()

        #expect(stale.calendarEnabled == true, "the saved instance adopts the switch on disk")
        let reloaded = ConfigService(configPath: path)
        #expect(reloaded.calendarEnabled == true)
        #expect(reloaded.gmailEnabled == true)
        #expect(reloaded.transcriptAudioRetentionDays == 10)
    }

    /// #740: a connect or Re-login from Settings turns the switches on from the
    /// CLI; the pane adopts them without a save and without dropping an
    /// unsaved edit elsewhere.
    @Test("Adopting the sync switches from disk keeps other unsaved edits")
    func adoptGoogleSyncSwitchesFromDisk() throws {
        let path = makeTempConfig("calendar:\n  enabled: false\ngmail:\n  enabled: false\n")
        let svc = ConfigService(configPath: path)
        svc.briefingHour = 10
        try "calendar:\n  enabled: true\ngmail:\n  enabled: true\n"
            .write(toFile: path, atomically: true, encoding: .utf8)

        svc.adoptGoogleSyncSwitchesFromDisk()

        #expect(svc.calendarEnabled == true)
        #expect(svc.gmailEnabled == true)
        #expect(svc.googleSyncSwitchesChanged == false, "an adopted switch needs no save")
        #expect(svc.briefingHour == 10, "an unsaved edit survives")
        svc.calendarEnabled = false
        #expect(svc.googleSyncSwitchesChanged == true, "an owner flip after adopting does")
    }

    @Test("Adopting from an unreadable config changes nothing")
    func adoptGoogleSyncSwitchesFromUnreadableConfig() throws {
        let path = makeTempConfig("calendar:\n  enabled: true\n")
        let svc = ConfigService(configPath: path)
        try "calendar: [unclosed\n".write(toFile: path, atomically: true, encoding: .utf8)

        svc.adoptGoogleSyncSwitchesFromDisk()

        #expect(svc.calendarEnabled == true)
        #expect(svc.googleSyncSwitchesChanged == false)
    }

    /// A fresh install's first Save (Goals' Continue writes the history depth)
    /// must not materialize `calendar.enabled: false` / `gmail.enabled: false`.
    @Test("Save of an untouched switch writes no enabled key")
    func saveOfUntouchedSwitchWritesNoKey() throws {
        let path = makeTempConfig("active_workspace: acme\n")
        let svc = ConfigService(configPath: path)
        svc.initialHistoryDays = 3
        try svc.save()

        let saved = try Yams.load(yaml: String(contentsOfFile: path, encoding: .utf8)) as? [String: Any]
        #expect((saved?["calendar"] as? [String: Any])?["enabled"] == nil)
        #expect((saved?["gmail"] as? [String: Any])?["enabled"] == nil)
    }

    /// The Settings toggle still turns a switch off: an edit made in this
    /// instance is written, and a second Save after it stays consistent.
    @Test("Save writes a switch the owner changed")
    func saveWritesChangedSwitch() throws {
        let path = makeTempConfig("calendar:\n  enabled: true\n")
        let svc = ConfigService(configPath: path)
        svc.calendarEnabled = false
        try svc.save()
        #expect(ConfigService(configPath: path).calendarEnabled == false)

        svc.calendarEnabled = true
        try svc.save()
        #expect(ConfigService(configPath: path).calendarEnabled == true)
    }

    /// Gmail has its own branch in `save()` (its section is written only on a
    /// change): turning Gmail sync off in Settings must still reach the file.
    @Test("Save writes a Gmail switch the owner changed")
    func saveWritesChangedGmailSwitch() throws {
        let path = makeTempConfig("gmail:\n  enabled: true\n")
        let svc = ConfigService(configPath: path)
        svc.gmailEnabled = false
        try svc.save()
        #expect(ConfigService(configPath: path).gmailEnabled == false)
    }

    /// #740: the Calendar tab reads the switch through `calendarSyncReadsOff`.
    /// A config.yaml that is present but not a YAML mapping is unknown, never
    /// "off" — or the tab would offer to fix a switch it cannot read.
    @Test("A present but undecodable config reads the switch as unknown")
    func undecodableConfigSwitchIsUnknown() throws {
        let notMapping = ConfigService(configPath: makeTempConfig("- just\n- a list\n"))
        #expect(notMapping.parseError != nil)
        #expect(notMapping.calendarSyncReadsOff == false)

        let badSyntax = ConfigService(configPath: makeTempConfig("calendar: [unclosed\n"))
        #expect(badSyntax.calendarSyncReadsOff == false)

        let path = makeTempConfig("")
        try Data([0xFF, 0xFE, 0x00]).write(to: URL(fileURLWithPath: path))
        #expect(ConfigService(configPath: path).calendarSyncReadsOff == false)
    }

    /// Degenerate: an empty document — blank, comments only, `null` — is an
    /// empty config (as the Go CLI reads it), not a broken one.
    @Test("An empty config document reads the switch as on (the default), without an error")
    func emptyConfigSwitchIsOn() {
        for yaml in ["", "  \n", "# just a comment\n", "---\n", "null\n"] {
            let svc = ConfigService(configPath: makeTempConfig(yaml))
            #expect(svc.parseError == nil, "\(yaml.debugDescription) is an empty config")
            #expect(svc.calendarSyncReadsOff == false)
        }
    }

    @Test("Turn on calendar sync writes the switch and keeps other keys")
    func turnOnCalendarSyncWritesSwitch() throws {
        let path = makeTempConfig("active_workspace: acme\ncalendar:\n  enabled: false\n")
        try ConfigService(configPath: path).turnOnCalendarSync()
        let reloaded = ConfigService(configPath: path)
        #expect(reloaded.calendarSyncReadsOff == false)
        #expect(reloaded.calendarEnabled == true)
        #expect(reloaded.activeWorkspace == "acme")
    }

    /// Saving over an unreadable file would fall back to the last good
    /// snapshot and drop every section the Desktop does not own.
    @Test("Turn on calendar sync refuses an unreadable config and leaves it untouched")
    func turnOnCalendarSyncRefusesUnreadableConfig() throws {
        let body = "calendar: [unclosed\njira:\n  token: keep\n"
        let path = makeTempConfig(body)
        #expect(throws: ConfigUnreadableError.self) {
            try ConfigService(configPath: path).turnOnCalendarSync()
        }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == body)
    }

    @Test("Load parses jira features")
    func loadJiraFeatures() {
        let path = makeTempConfig("""
        jira:
          features:
            briefings: true
            recommendations: false
        """)
        let svc = ConfigService(configPath: path)
        #expect(svc.jiraFeatures["briefings"] == true)
        #expect(svc.jiraFeatures["recommendations"] == false)
    }

    @Test("Load applies default transcript audio retention when section missing")
    func loadTranscriptRetentionDefault() {
        let path = makeTempConfig("active_workspace: x\n")
        let svc = ConfigService(configPath: path)
        #expect(svc.transcriptAudioRetentionDays == 30)
    }

    @Test("Load parses transcripts section")
    func loadTranscripts() {
        let path = makeTempConfig("""
        transcripts:
          audio_retention_days: 7
        """)
        let svc = ConfigService(configPath: path)
        #expect(svc.transcriptAudioRetentionDays == 7)
    }

    @Test("Save round-trips transcript audio retention")
    func saveTranscriptRetention() throws {
        let path = makeTempConfig("active_workspace: x\n")
        let svc = ConfigService(configPath: path)
        svc.transcriptAudioRetentionDays = 14
        try svc.save()

        let svc2 = ConfigService(configPath: path)
        #expect(svc2.transcriptAudioRetentionDays == 14)
    }

    @Test("Save round-trips dirty values")
    func saveRoundTrip() throws {
        let path = makeTempConfig("active_workspace: old\n")
        let svc = ConfigService(configPath: path)
        svc.activeWorkspace = "new-ws"
        svc.aiProvider = "codex"
        svc.calendarEnabled = true
        svc.calendarSyncDaysAhead = 7
        svc.transcriptAudioRetentionDays = 11
        try svc.save()

        let svc2 = ConfigService(configPath: path)
        // active_workspace is CLI-owned: even a dirty in-memory value is not written.
        #expect(svc2.activeWorkspace == "old")
        #expect(svc2.aiProvider == "codex")
        #expect(svc2.calendarEnabled == true)
        #expect(svc2.calendarSyncDaysAhead == 7)
        #expect(svc2.transcriptAudioRetentionDays == 11)
    }

    @Test("Save sets file permissions to 0600")
    func savePermissions() throws {
        let path = makeTempConfig("active_workspace: x\n")
        let svc = ConfigService(configPath: path)
        svc.activeWorkspace = "y"
        try svc.save()

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perm = attrs[.posixPermissions] as? NSNumber
        #expect(perm?.intValue == 0o600, "expected owner-only permissions, got \(String(describing: perm))")
    }

    @Test("Save removes empty optional strings")
    func saveRemovesEmptyValues() throws {
        let path = makeTempConfig("""
        ai:
          model: keepme
          provider: claude
        """)
        let svc = ConfigService(configPath: path)
        svc.aiModel = ""
        svc.aiProvider = nil
        try svc.save()

        let raw = try String(contentsOfFile: path, encoding: .utf8)
        #expect(!raw.contains("model:"), "empty model should be removed; got: \(raw)")
        #expect(!raw.contains("provider:"), "nil provider should be removed; got: \(raw)")
    }

    @Test("Reload on bad YAML records parseError but doesn't crash")
    func reloadBadYAML() {
        let path = makeTempConfig("not: a: valid: yaml: at: all\n  - mismatch")
        let svc = ConfigService(configPath: path)
        // parseError is set when YAML can't be parsed.
        // (In some cases bad YAML still parses to a non-dictionary, leaving parseError nil.)
        _ = svc.parseError
    }

    @Test("Reload on missing file leaves defaults untouched")
    func reloadMissingFile() {
        let svc = ConfigService(configPath: "/nonexistent/path/to/config.yaml")
        #expect(svc.activeWorkspace == nil)
        #expect(svc.briefingHour == 8) // default
        #expect(svc.dayPlanEnabled == true) // default
        #expect(svc.ideasEnabled == true) // default
    }

    @Test("Save merges onto sections written concurrently by a CLI login, not the stale in-memory snapshot")
    func saveDoesNotClobberConcurrentCLIWrites() throws {
        let path = makeTempConfig("""
        jira:
          project_key: X
        ai:
          provider: claude
        """)
        let svc = ConfigService(configPath: path)

        // Simulate a CLI flow (e.g. `watchtower jira login`) writing new
        // fields to disk *after* ConfigService loaded its in-memory snapshot.
        try """
        jira:
          project_key: X
          api_token: secret-from-cli-login
        ai:
          provider: claude
        """.write(toFile: path, atomically: true, encoding: .utf8)

        svc.aiProvider = "codex"
        try svc.save()

        let raw = try String(contentsOfFile: path, encoding: .utf8)
        let yaml = try Yams.load(yaml: raw) as? [String: Any]
        let jira = yaml?["jira"] as? [String: Any]
        #expect(jira?["project_key"] as? String == "X", "section Desktop doesn't own must survive; got: \(raw)")
        #expect(jira?["api_token"] as? String == "secret-from-cli-login", "concurrent CLI write must survive; got: \(raw)")

        let ai = yaml?["ai"] as? [String: Any]
        #expect(ai?["provider"] as? String == "codex", "Desktop-owned field must still be updated; got: \(raw)")
    }

    /// `workbench.default_agent` (board #399, D1): read as Go reads it, written
    /// back without touching the rest of the `workbench` section.
    @Test("Default agent round-trips the config")
    func testDefaultAgentSettingRoundTripsConfig() throws {
        let path = makeTempConfig("""
        workbench:
          default_agent: codex
          other_key: kept
        """)
        let svc = ConfigService(configPath: path)
        #expect(svc.workbenchDefaultAgent == .codex)

        svc.workbenchDefaultAgent = .claude
        try svc.save()
        var saved = try Yams.load(yaml: String(contentsOfFile: path, encoding: .utf8)) as? [String: Any]
        var workbench = saved?["workbench"] as? [String: Any]
        #expect(workbench?["default_agent"] as? String == "claude", "a value on disk is overwritten, not dropped")
        #expect(workbench?["other_key"] as? String == "kept")

        svc.workbenchDefaultAgent = .codex
        try svc.save()
        saved = try Yams.load(yaml: String(contentsOfFile: path, encoding: .utf8)) as? [String: Any]
        workbench = saved?["workbench"] as? [String: Any]
        #expect(workbench?["default_agent"] as? String == "codex")
        #expect(ConfigService(configPath: path).workbenchDefaultAgent == .codex)
    }

    /// Missing, empty, unknown or wrong-case values read Claude Code (Go's
    /// `WorkbenchConfig.Agent()`), and a fresh config gains no section.
    @Test("Default agent degenerate values read Claude Code")
    func testDefaultAgentDegenerateValuesReadClaude() throws {
        for yaml in ["sync:\n  workers: 1", "workbench: {}", "workbench:\n  default_agent: \"\"",
                     "workbench:\n  default_agent: Codex", "workbench:\n  default_agent: gemini",
                     "workbench:\n  default_agent: 3", "workbench: codex"] {
            #expect(ConfigService(configPath: makeTempConfig(yaml)).workbenchDefaultAgent == .claude, "\(yaml)")
        }
        let path = makeTempConfig("sync:\n  workers: 1")
        try ConfigService(configPath: path).save()
        let saved = try Yams.load(yaml: String(contentsOfFile: path, encoding: .utf8)) as? [String: Any]
        #expect(saved?["workbench"] == nil, "the Claude default writes nothing on a fresh config")
    }

    /// `privacy.purge_revoked_data` (board #601) is tri-state: absent stays
    /// absent on Save (the build default applies), a set value round-trips
    /// and the section's other keys are kept.
    @Test("Purge on revoked access round-trips and stays absent until set")
    func testPurgeRevokedDataRoundTrips() throws {
        let fresh = makeTempConfig("sync:\n  workers: 1")
        let svc = ConfigService(configPath: fresh)
        #expect(svc.purgeRevokedData == nil)
        try svc.save()
        var saved = try Yams.load(yaml: String(contentsOfFile: fresh, encoding: .utf8)) as? [String: Any]
        #expect(saved?["privacy"] == nil, "absent stays absent")

        #expect(!svc.lastSaveChangedPurge)
        svc.purgeRevokedData = false
        try svc.save()
        #expect(svc.lastSaveChangedPurge, "a new value asks for a daemon restart")
        try svc.save()
        #expect(!svc.lastSaveChangedPurge, "an unchanged value does not")
        saved = try Yams.load(yaml: String(contentsOfFile: fresh, encoding: .utf8)) as? [String: Any]
        #expect((saved?["privacy"] as? [String: Any])?["purge_revoked_data"] as? Bool == false, "an explicit off is written")

        let path = makeTempConfig("privacy:\n  purge_revoked_data: true\n  other_key: kept")
        let on = ConfigService(configPath: path)
        #expect(on.purgeRevokedData == true)
        on.purgeRevokedData = false
        try on.save()
        saved = try Yams.load(yaml: String(contentsOfFile: path, encoding: .utf8)) as? [String: Any]
        let privacy = saved?["privacy"] as? [String: Any]
        #expect(privacy?["purge_revoked_data"] as? Bool == false)
        #expect(privacy?["other_key"] as? String == "kept")
    }

    /// #899: the shared copy re-reads config.yaml when Settings or the
    /// Connections tab shows, unless an edit waits for Save.
    @Test("reloadUnlessEdited picks up the disk and keeps unsaved edits")
    func reloadUnlessEdited() throws {
        let path = makeTempConfig("claude_path: /opt/a\n")
        let svc = ConfigService(configPath: path)
        #expect(!svc.hasUnsavedEdits)

        try "claude_path: /opt/b\n".write(toFile: path, atomically: true, encoding: .utf8)
        svc.reloadUnlessEdited()
        #expect(svc.claudePath == "/opt/b", "a change on disk since the last load shows")

        svc.codexPath = "/opt/mine"
        #expect(svc.hasUnsavedEdits)
        try "claude_path: /opt/c\n".write(toFile: path, atomically: true, encoding: .utf8)
        svc.reloadUnlessEdited()
        #expect(svc.codexPath == "/opt/mine", "an unsaved edit is kept")
        #expect(svc.claudePath == "/opt/b")

        try svc.save()
        #expect(!svc.hasUnsavedEdits, "saved: nothing waits")
    }

    /// A Google connect turns its sync switches on from the CLI: adopting
    /// them is not an edit, so later reloads still run; an edit elsewhere
    /// still counts.
    @Test("adopting the Google switches from disk moves only them into the baseline")
    func adoptedSwitchesAreNoEdit() throws {
        let path = makeTempConfig("calendar:\n  enabled: false\ngmail:\n  enabled: false\n")
        let svc = ConfigService(configPath: path)
        #expect(!svc.calendarEnabled)

        try "calendar:\n  enabled: true\ngmail:\n  enabled: true\n".write(toFile: path, atomically: true, encoding: .utf8)
        svc.adoptGoogleSyncSwitchesFromDisk()
        #expect(svc.calendarEnabled && svc.gmailEnabled)
        #expect(!svc.hasUnsavedEdits, "what came from disk is no edit")

        try "calendar:\n  enabled: true\ngmail:\n  enabled: true\nclaude_path: /opt/new\n"
            .write(toFile: path, atomically: true, encoding: .utf8)
        svc.reloadUnlessEdited()
        #expect(svc.claudePath == "/opt/new", "a later reload still runs")

        svc.codexPath = "/opt/mine"
        try "calendar:\n  enabled: false\ngmail:\n  enabled: true\n".write(toFile: path, atomically: true, encoding: .utf8)
        svc.adoptGoogleSyncSwitchesFromDisk()
        #expect(svc.hasUnsavedEdits, "the unsaved edit elsewhere still counts")
    }

    /// An equal dictionary in another key order is no edit (`jiraFeatures`
    /// prints its keys in hash order).
    @Test("a dictionary field rebuilt with the same values is no edit")
    func dictionaryFieldComparedByValue() {
        let keys = (0..<40).map { "signal_\($0)" }
        let path = makeTempConfig("jira:\n  features:\n" + keys.map { "    \($0): true\n" }.joined())
        let svc = ConfigService(configPath: path)
        #expect(svc.jiraFeatures.count == 40)
        svc.jiraFeatures = Dictionary(uniqueKeysWithValues: keys.reversed().map { ($0, true) })
        #expect(!svc.hasUnsavedEdits)
        svc.jiraFeatures["signal_0"] = false
        #expect(svc.hasUnsavedEdits)
    }
}

extension ConfigServiceTests {
    @Test("Apply and Retry read latest saved metadata without rewriting a newer Save")
    func routingApplyReadsLatestSaved() async throws {
        let path = makeTempConfig("ai: {provider: claude}")
        var revision = "first"
        let service = ConfigService(configPath: path) {
            try ChatRoutingStatus.parse(Data("""
                {"revision":"\(revision)","saved_version":"current-file","preferred_provider":"codex",
                 "enabled":true,"providers":[],"application":{"identity":"current-run",
                 "revision":"\(revision)","saved_version":"current-file","preferred_provider":"codex"}}
                """.utf8))
        }
        service.selectAIProvider("codex")
        try service.save()
        #expect(service.routingApplication.phase == .applying)
        #expect(!service.hasUnsavedEdits)
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        revision = "newer-save"
        await service.applySavedRouting()
        #expect(service.routingApplication.phase == .applied)
        #expect(service.routingApplication.savedRevision == "newer-save")
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before)
        #expect(!service.hasUnsavedEdits)
    }
}

extension ConfigServiceTests {
    @Test("A separate save failure does not strand saved routing in Applying")
    func routingApplyCompletesAfterExtraSaveFailure() async throws {
        let path = makeTempConfig("ai: {provider: claude}")
        var reads = 0
        let service = ConfigService(configPath: path) {
            reads += 1
            return try ChatRoutingStatus.parse(Data("""
                {"revision":"saved","saved_version":"current","preferred_provider":"claude",
                 "enabled":false,"providers":[],"application":{"identity":"run","revision":"saved",
                 "saved_version":"current","preferred_provider":"claude"}}
                """.utf8))
        }
        do {
            try await service.saveAndApply { throw CocoaError(.fileWriteNoPermission) }
            Issue.record("The independent save error must remain visible")
        } catch {
            #expect((error as NSError).code == CocoaError.fileWriteNoPermission.rawValue)
        }
        #expect(reads == 1)
        #expect(service.routingApplication.phase == .applied)
        #expect(!service.hasUnsavedEdits)
    }
}

extension ConfigServiceTests {
    @Test("Reloading a different workspace rejects an older pending acknowledgement")
    func workspaceReloadInvalidatesPendingRoutingAck() async throws {
        let path = makeTempConfig("active_workspace: first\nai: {provider: claude}")
        var pending: CheckedContinuation<ChatRoutingStatus, Never>?
        let service = ConfigService(configPath: path) {
            await withCheckedContinuation { pending = $0 }
        }
        let task = Task { await service.applySavedRouting() }
        while pending == nil { await Task.yield() }
        try "active_workspace: second\nai: {provider: claude}".write(toFile: path, atomically: true, encoding: .utf8)
        service.reload()
        let old = try ChatRoutingStatus.parse(Data("""
            {"revision":"old","saved_version":"old","preferred_provider":"claude","enabled":false,"providers":[],
             "application":{"identity":"old-run","revision":"old","saved_version":"old","preferred_provider":"claude"}}
            """.utf8))
        pending?.resume(returning: old)
        await task.value
        #expect(service.activeWorkspace == "second")
        #expect(service.routingApplication.phase == .failed)
        #expect(service.routingApplication.confirmed == nil)
        #expect(service.routingApplication.savedRevision == nil)
    }
}

extension ConfigServiceTests {
    @Test("Same-workspace Reload revokes old applied and pending acknowledgements")
    func sameWorkspaceReloadRejectsOldAppliedAndPendingAck() async throws {
        func status(_ revision: String, _ provider: String) throws -> ChatRoutingStatus {
            try ChatRoutingStatus.parse(Data("""
                {"revision":"\(revision)","saved_version":"\(revision)","preferred_provider":"\(provider)",
                 "enabled":false,"providers":[],"application":{"identity":"run","revision":"\(revision)",
                 "saved_version":"\(revision)","preferred_provider":"\(provider)"}}
                """.utf8))
        }
        let path = makeTempConfig("active_workspace: first\nai: {provider: claude}")
        let old = try status("A", "claude")
        var current = old
        var block = false
        var pending: CheckedContinuation<ChatRoutingStatus, Never>?
        let service = ConfigService(configPath: path) {
            if block { return await withCheckedContinuation { pending = $0 } }
            return current
        }
        await service.applySavedRouting()
        #expect(service.routingApplication.phase == .applied)
        block = true
        let task = Task { await service.applySavedRouting() }
        while pending == nil { await Task.yield() }
        let saved = "active_workspace: first\nai: {provider: codex}"
        try saved.write(toFile: path, atomically: true, encoding: .utf8)
        service.reload()
        #expect(service.routingApplication.phase == .failed)
        #expect(service.aiProvider == "codex")
        pending?.resume(returning: old)
        await task.value
        #expect(service.routingApplication.phase == .failed)
        #expect(service.routingApplication.confirmed == nil)
        block = false
        current = try status("B", "codex")
        await service.applySavedRouting()
        #expect(service.routingApplication.phase == .applied)
        #expect(service.routingApplication.savedRevision == "B")
        #expect(try String(contentsOfFile: path, encoding: .utf8) == saved)
    }
}

import Foundation
import Observation

/// The Goals step's AI CLI check (`watchtower ai test`): Continue is blocked
/// until it is `.ready` (owner decision — every AI feature runs on the CLI).
package enum OnboardingCLICheck: Equatable, Sendable {
    case checking
    /// `provider` is the configured `ai.provider` the test answered for.
    case ready(provider: String)
    case failed(String)
}

/// What Continue on the Goals step does to the outside world, injected so
/// the ordering and the exactly-once workspace init are testable.
package struct OnboardingGoalsActions {
    /// `watchtower workspace init --json`.
    package var initWorkspace: () async throws -> Void
    /// `watchtower config set digest.language <name>`.
    package var setLanguage: (String) async throws -> Void
    /// Applies the feature selection; returns the failure to show (nil when
    /// every change landed) and whether any feature actually changed.
    package var applyFeatures: (OnboardingFeatureSelection) async -> (failure: String?, changed: Bool)
    /// Whether the config has no `sync.initial_history_days` yet — read
    /// before `workspace init`, which fills in Go's default.
    package var historyDepthUnset: @MainActor () -> Bool
    /// `watchtower config set sync.initial_history_days <days>`.
    package var setHistoryDepth: (Int) async throws -> Void

    package init(
        initWorkspace: @escaping () async throws -> Void,
        setLanguage: @escaping (String) async throws -> Void,
        applyFeatures: @escaping (OnboardingFeatureSelection) async -> (failure: String?, changed: Bool),
        historyDepthUnset: @escaping @MainActor () -> Bool = { false },
        setHistoryDepth: @escaping (Int) async throws -> Void = { _ in }
    ) {
        self.initWorkspace = initWorkspace
        self.setLanguage = setLanguage
        self.applyFeatures = applyFeatures
        self.historyDepthUnset = historyDepthUnset
        self.setHistoryDepth = setHistoryDepth
    }
}

/// Onboarding's Goals step: the goals and feature selection, the assistant
/// language, the AI CLI check and Continue. Lives in `AppState` so the
/// selection survives the Customize screen and a running check or Continue
/// survives the step re-rendering.
@MainActor
@Observable
package final class OnboardingGoalsModel {
    /// The goals of the last successful Continue, which the route of a
    /// relaunch (`OnboardingStateMachineV2.settle`) and the step indicator
    /// read — never the live checkboxes, so the dots do not move while the
    /// owner is still picking.
    package static let goalsKey = "onboarding_v2_goals"
    /// All but Meetings: its calendar connection and transcription model are
    /// the heaviest setup, opted into deliberately.
    package static let defaultGoals: Set<OnboardingGoal> = [.workCommunication, .tasksAndJira, .development]
    /// The Slack history the first sync fetches when nothing set it: the
    /// old onboarding's default pick, kept so a fresh install syncs as much
    /// as it used to.
    package static let defaultHistoryDays = 3

    package var selection: OnboardingFeatureSelection
    /// An English language name, the `digest.language` value Continue writes.
    package var language: String
    /// The Customize features screen is showing in place of the goals.
    package var isCustomizingFeatures = false
    package private(set) var cliCheck: OnboardingCLICheck = .checking
    package private(set) var isContinuing = false
    package private(set) var continueError: String?
    package private(set) var savedGoals: Set<OnboardingGoal>
    /// A Continue of this run changed the config (language, history depth)
    /// or a feature: the daemon needs a restart to pick it up.
    package private(set) var wroteChanges = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let checkCLI: () async -> OnboardingCLICheck
    @ObservationIgnored private let actions: OnboardingGoalsActions
    @ObservationIgnored private var cliCheckGeneration = 0
    /// The check in flight; a second request joins it instead of running
    /// another `ai test`.
    @ObservationIgnored private var cliCheckTask: Task<Void, Never>?
    /// A check ran (or runs) since the last setup start: the step
    /// re-appearing (Goals ↔ Customize) does not run another.
    @ObservationIgnored private var cliCheckStarted = false
    @ObservationIgnored private var languagePrepared = false
    /// The language the config already holds on a re-run; Continue writes
    /// the language only when it differs.
    @ObservationIgnored private var configuredLanguage: String?
    /// Set once `workspace init` succeeded: a second Continue (back from
    /// Connect) does not run it again.
    @ObservationIgnored private var workspaceReady = false

    package init(
        defaults: UserDefaults = .standard,
        systemLanguage: String = AssistantLanguageCatalog.systemDefault().englishName,
        checkCLI: @escaping () async -> OnboardingCLICheck,
        actions: OnboardingGoalsActions
    ) {
        self.defaults = defaults
        self.checkCLI = checkCLI
        self.actions = actions
        let saved = (defaults.stringArray(forKey: Self.goalsKey)?.compactMap(OnboardingGoal.init(rawValue:)))
            .map(Set.init) ?? Self.defaultGoals
        savedGoals = saved
        selection = OnboardingFeatureSelection(goals: saved)
        language = systemLanguage
    }

    /// The route the indicator and a relaunch follow.
    package func route(hasSlackAccount: Bool) -> OnboardingRoute {
        OnboardingRoute(goals: savedGoals, hasSlackAccount: hasSlackAccount)
    }

    package var canContinue: Bool {
        guard case .ready = cliCheck else { return false }
        return !isContinuing
    }

    /// Called when the step appears: adopts an already configured language
    /// once (a setup re-run keeps the owner's choice instead of the macOS
    /// default), and runs the CLI check once per setup run — Check again is
    /// the owner's way to repeat it.
    package func prepare(configuredLanguage: String?) async {
        if !languagePrepared {
            languagePrepared = true
            if let configured = configuredLanguage?.trimmingCharacters(in: .whitespaces), !configured.isEmpty {
                language = configured
            }
        }
        guard !cliCheckStarted else {
            await cliCheckTask?.value
            return
        }
        await runCLICheck()
    }

    /// Check again. Joins a check already in flight. A check that finishes
    /// after `prepareForRerun` reset the step is dropped, so a slow old run
    /// cannot overwrite a later result.
    package func runCLICheck() async {
        if let cliCheckTask {
            await cliCheckTask.value
            return
        }
        cliCheckStarted = true
        cliCheckGeneration += 1
        let generation = cliCheckGeneration
        cliCheck = .checking
        let task = Task { [checkCLI] in
            let result = await checkCLI()
            guard generation == cliCheckGeneration else { return }
            cliCheck = result
            cliCheckTask = nil
        }
        cliCheckTask = task
        await task.value
    }

    /// "Run setup again": the step starts over as if just shown — the CLI is
    /// checked again, the configured language adopted again, no error or
    /// Customize screen left from the last run. The goals and selection stay.
    package func prepareForRerun() {
        cliCheckGeneration += 1
        cliCheckTask = nil
        cliCheckStarted = false
        cliCheck = .checking
        continueError = nil
        languagePrepared = false
        configuredLanguage = nil
        isCustomizingFeatures = false
        wroteChanges = false
    }

    /// "Run setup again" starts from what is in effect now: the feature set
    /// (`OnboardingFeatureSelection.current`) and the configured language
    /// (`language`, English when the config names none — Go's default),
    /// never the macOS default.
    package func seedForRerun(enabledFeatureIDs: Set<String>, language: String) {
        prepareForRerun()
        selection = OnboardingFeatureSelection.current(enabledIDs: enabledFeatureIDs, savedGoals: savedGoals)
        self.language = language
        configuredLanguage = language
        languagePrepared = true
    }

    package func toggle(_ goal: OnboardingGoal) {
        if selection.goals.contains(goal) {
            selection.goals.remove(goal)
        } else {
            selection.goals.insert(goal)
        }
    }

    /// Continue: the workspace first when there is no Slack account (the
    /// features CLI and the Connect step's account sheets need one), then
    /// the language, then the features. Stops at the first failure with
    /// `continueError` set and returns nil; on success persists the goals and
    /// returns the route to advance by. Zero goals is allowed — the
    /// Development-only path.
    package func submit(hasSlackAccount: Bool) async -> OnboardingRoute? {
        guard canContinue else { return nil }
        isContinuing = true
        continueError = nil
        defer { isContinuing = false }

        let historyUnset = actions.historyDepthUnset()
        if !hasSlackAccount && !workspaceReady {
            do {
                try await actions.initWorkspace()
                workspaceReady = true
            } catch {
                continueError = "Could not create the workspace: \(error.localizedDescription)"
                return nil
            }
        }
        if historyUnset {
            do {
                try await actions.setHistoryDepth(Self.defaultHistoryDays)
                wroteChanges = true
            } catch {
                continueError = "Could not save the history depth: \(error.localizedDescription)"
                return nil
            }
        }
        do {
            if language != configuredLanguage {
                try await actions.setLanguage(language)
                configuredLanguage = language
                wroteChanges = true
            }
        } catch {
            continueError = "Could not save the assistant language: \(error.localizedDescription)"
            return nil
        }
        let applied = await actions.applyFeatures(selection)
        if applied.changed { wroteChanges = true }
        if let failure = applied.failure {
            continueError = failure
            return nil
        }
        savedGoals = selection.goals
        defaults.set(selection.goals.map(\.rawValue).sorted(), forKey: Self.goalsKey)
        return route(hasSlackAccount: hasSlackAccount)
    }
}

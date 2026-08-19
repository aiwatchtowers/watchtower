import Foundation
import Testing
import WatchtowerCore
import WatchtowerTestSupport
@testable import WatchtowerDesktop

@MainActor
@Suite("FeatureManagerService")
struct FeatureManagerServiceTests {
    // MARK: - Fixtures
    //
    // Field names mirror the Go wire contract exactly (`cmd/features.go`'s
    // featureJSON/subToggleJSON/disableResultJSON) — see `internal/features/registry.go`
    // for the real "ideas"/"tracks"/"memory" entries this loosely echoes.

    private static let featuresListJSON = """
    {"features":[
      {
        "id":"ideas","title":"Ideas & Decisions","description":"Mines ideas.",
        "tagline":"Every idea and decision, kept in one registry",
        "benefits":[
          "Proposed ideas and decisions mined from Slack, email, Jira and meetings",
          "Consolidated into one registry for your review",
          "Nothing decided in passing gets forgotten"
        ],
        "icon":"lightbulb",
        "state":"enabled","core":false,"parent":"","config_key":"ideas.enabled",
        "cost":"medium","feeds_into":[],"sub_toggles":[]
      },
      {
        "id":"tracks","title":"Tracks","description":"Narrative tracks.",
        "tagline":"Follow the story of a project, not just its messages",
        "benefits":[
          "Multi-message threads and projects tracked as one ongoing narrative",
          "Define your own custom tracks to watch",
          "Feeds the daily Briefing with what moved"
        ],
        "icon":"binoculars",
        "state":"disabled","core":false,"parent":"","config_key":"tracks.enabled",
        "cost":"heavy","feeds_into":["briefing","memory"],"sub_toggles":[]
      },
      {
        "id":"memory","title":"Memory","description":"Long-term memory vault.",
        "tagline":"An assistant that remembers, not just reacts",
        "benefits":[
          "Durable memory of people, projects and beliefs",
          "Later answers and briefings start with real context, not a blank slate",
          "Feeds the daily Briefing and Day Plan once it's on"
        ],
        "icon":"archivebox",
        "state":"disabled","core":false,"parent":"","config_key":"memory.enabled",
        "cost":"medium","feeds_into":["briefing","day-plan"],
        "sub_toggles":[
          {
            "key":"memory.semantic.enabled","title":"Semantic tier",
            "description":"Strong-tier rewrites.","enabled":false
          }
        ]
      },
      {
        "id":"dashboard","title":"Dashboard","description":"The home screen.",
        "tagline":"Everything that needs you, in one place",
        "benefits":[
          "Situations from Slack, email, Jira and calendar merged into one view",
          "A situation card explains why each one matters",
          "Discuss each situation directly with your assistant"
        ],
        "icon":"tray",
        "state":"core","core":true,"parent":"","config_key":"","cost":"none",
        "feeds_into":[],"sub_toggles":[]
      }
    ]}
    """

    /// Same as `featuresListJSON` but with "ideas" already disabled — models
    /// what a reload returns after a batch's "ideas" call succeeded before a
    /// later call in the same batch failed.
    private static let featuresListAfterIdeasDisabledJSON = """
    {"features":[
      {
        "id":"ideas","title":"Ideas & Decisions","description":"Mines ideas.",
        "tagline":"Every idea and decision, kept in one registry",
        "benefits":[
          "Proposed ideas and decisions mined from Slack, email, Jira and meetings",
          "Consolidated into one registry for your review",
          "Nothing decided in passing gets forgotten"
        ],
        "icon":"lightbulb",
        "state":"disabled","core":false,"parent":"","config_key":"ideas.enabled",
        "cost":"medium","feeds_into":[],"sub_toggles":[]
      },
      {
        "id":"tracks","title":"Tracks","description":"Narrative tracks.",
        "tagline":"Follow the story of a project, not just its messages",
        "benefits":[
          "Multi-message threads and projects tracked as one ongoing narrative",
          "Define your own custom tracks to watch",
          "Feeds the daily Briefing with what moved"
        ],
        "icon":"binoculars",
        "state":"disabled","core":false,"parent":"","config_key":"tracks.enabled",
        "cost":"heavy","feeds_into":["briefing","memory"],"sub_toggles":[]
      },
      {
        "id":"memory","title":"Memory","description":"Long-term memory vault.",
        "tagline":"An assistant that remembers, not just reacts",
        "benefits":[
          "Durable memory of people, projects and beliefs",
          "Later answers and briefings start with real context, not a blank slate",
          "Feeds the daily Briefing and Day Plan once it's on"
        ],
        "icon":"archivebox",
        "state":"disabled","core":false,"parent":"","config_key":"memory.enabled",
        "cost":"medium","feeds_into":["briefing","day-plan"],
        "sub_toggles":[
          {
            "key":"memory.semantic.enabled","title":"Semantic tier",
            "description":"Strong-tier rewrites.","enabled":false
          }
        ]
      },
      {
        "id":"dashboard","title":"Dashboard","description":"The home screen.",
        "tagline":"Everything that needs you, in one place",
        "benefits":[
          "Situations from Slack, email, Jira and calendar merged into one view",
          "A situation card explains why each one matters",
          "Discuss each situation directly with your assistant"
        ],
        "icon":"tray",
        "state":"core","core":true,"parent":"","config_key":"","cost":"none",
        "feeds_into":[],"sub_toggles":[]
      }
    ]}
    """

    private static let dependentsJSON = """
    {"feature":"memory","dependents":[{"id":"briefing","title":"Daily Briefing"},{"id":"day-plan","title":"Day Plan"}]}
    """

    private static func makeService(stdout: String, error: Error? = nil) -> (FeatureManagerService, FakeCLIRunner) {
        let runner = FakeCLIRunner(stdout: Data(stdout.utf8), error: error)
        let service = FeatureManagerService(runner: runner)
        return (service, runner)
    }

    // MARK: - load()

    @Test("load() decodes the features list, mapping snake_case wire fields")
    func loadDecodes() async throws {
        let (service, runner) = Self.makeService(stdout: Self.featuresListJSON)
        await service.load()

        #expect(service.loadError == nil)
        #expect(service.features.count == 4)
        #expect(runner.invocations == [["features", "list", "--json"]])

        let memory = try #require(service.features.first { $0.id == "memory" })
        #expect(memory.configKey == "memory.enabled")
        #expect(memory.feedsInto == ["briefing", "day-plan"])
        #expect(memory.subToggles.first?.key == "memory.semantic.enabled")
        #expect(memory.subToggles.first?.enabled == false)
        #expect(memory.tagline == "An assistant that remembers, not just reacts")
        #expect(memory.benefits.count == 3)
        #expect(memory.benefits.first == "Durable memory of people, projects and beliefs")
        #expect(memory.icon == "archivebox")

        let dashboard = try #require(service.features.first { $0.id == "dashboard" })
        #expect(dashboard.core == true)
        #expect(dashboard.state == "core")
        #expect(dashboard.tagline == "Everything that needs you, in one place")
        #expect(dashboard.icon == "tray")
    }

    @Test("load() surfaces a CLI failure via loadError and leaves features empty")
    func loadSurfacesFailure() async {
        let (service, _) = Self.makeService(
            stdout: "",
            error: CLIRunnerError.nonZeroExit(code: 1, stderr: "boom: config missing")
        )
        await service.load()

        #expect(service.features.isEmpty)
        #expect(service.loadError?.contains("boom: config missing") == true)
    }

    @Test("load() decodes an empty benefits array as [], not null — Go always marshals []")
    func loadDecodesEmptyBenefitsArray() async throws {
        // Mirrors `dependentsDecodesEmptyList` below: the Go side never emits
        // a nil slice here (`append([]string{}, f.Benefits...)` in
        // cmd/features.go), but a non-optional Swift `[String]` would throw
        // on decode if that ever regressed to `null` — pin the wire shape.
        let json = """
        {"features":[
          {
            "id":"next-step","title":"Next Step","description":"Suggests actions.",
            "tagline":"Always know what to do next","benefits":[],"icon":"arrow.turn.down.right",
            "state":"disabled","core":false,"parent":"","config_key":"targets.next_step.enabled",
            "cost":"medium","feeds_into":[],"sub_toggles":[]
          }
        ]}
        """
        let (service, _) = Self.makeService(stdout: json)
        await service.load()

        #expect(service.loadError == nil)
        let feature = try #require(service.features.first)
        #expect(feature.benefits.isEmpty)
    }

    // MARK: - disabledFeatureIDs

    @Test("disabledFeatureIDs folds pending over the last-loaded state, pending wins either direction")
    func disabledFeatureIDsFoldsPending() async {
        let (service, _) = Self.makeService(stdout: Self.featuresListJSON)
        await service.load()

        // Baseline from the loaded state alone: tracks + memory are disabled.
        #expect(service.disabledFeatureIDs == ["tracks", "memory"])

        // Staging a disable on an enabled feature adds it.
        service.setPending("ideas", enabled: false)
        #expect(service.disabledFeatureIDs == ["tracks", "memory", "ideas"])

        // Staging an enable on a disabled feature removes it, even though
        // the last-loaded snapshot still says disabled.
        service.setPending("tracks", enabled: true)
        #expect(service.disabledFeatureIDs == ["memory", "ideas"])

        // A staged SUB-TOGGLE is keyed by its config key, not a feature id,
        // and must never land in a set of feature ids. Staged ON, because
        // it loads as false and setPending drops an entry that matches the
        // loaded state — staging it off would leave nothing staged at all,
        // and this assertion would then hold vacuously.
        service.setPending("memory.semantic.enabled", enabled: true)
        #expect(service.pending["memory.semantic.enabled"] == true)
        #expect(service.disabledFeatureIDs == ["memory", "ideas"])
    }

    // MARK: - setPending()

    @Test("setPending() drops an entry that matches the loaded state: toggling off then back on leaves nothing staged")
    func setPendingDropsNoOpFeatureEntry() async {
        let (service, runner) = Self.makeService(stdout: Self.featuresListJSON)
        await service.load()

        // "ideas" is loaded enabled. Off is a real change...
        service.setPending("ideas", enabled: false)
        #expect(service.pending == ["ideas": false])
        // ...and back on returns it to exactly the loaded state.
        service.setPending("ideas", enabled: true)
        #expect(service.pending.isEmpty, "nothing left to apply")

        // Left staged, `features enable ideas` would run its fast-forward
        // hook (FEAT-03) and reset the watermarks of a feature that was never
        // off, skipping past freshly-synced history.
        let spy = RestartSpy()
        await service.apply { await spy.restart() }

        #expect(runner.invocations == [["features", "list", "--json"]], "only the seed load(); apply() had nothing to do")
        #expect(spy.callCount == 0)
    }

    @Test("setPending() keeps an entry that really differs from the loaded state")
    func setPendingKeepsRealChange() async {
        let (service, _) = Self.makeService(stdout: Self.featuresListJSON)
        await service.load()

        // "tracks" is loaded disabled, so enabling it is a genuine change.
        service.setPending("tracks", enabled: true)
        #expect(service.pending == ["tracks": true])
    }

    @Test("setPending() applies the same drop-on-equal rule to a sub-toggle key, which has no feature entry of its own")
    func setPendingDropsNoOpSubToggleEntry() async {
        let (service, _) = Self.makeService(stdout: Self.featuresListJSON)
        await service.load()

        // "memory.semantic.enabled" is loaded false — named by config key,
        // found on its parent's subToggles rather than as a feature id.
        service.setPending("memory.semantic.enabled", enabled: true)
        #expect(service.pending == ["memory.semantic.enabled": true])
        service.setPending("memory.semantic.enabled", enabled: false)
        #expect(service.pending.isEmpty)
    }

    @Test("setPending() stages a key nothing loaded knows about as-is")
    func setPendingStagesUnknownKeyAsIs() async {
        let (service, _) = Self.makeService(stdout: Self.featuresListJSON)

        // No load() — `features` is empty, so even a real feature id has no
        // known current state to compare against. Dropping the entry here
        // would silently lose a choice made before the list arrived (the
        // stage-then-load path `loadInvokesOnDisabledChangedWithPendingFolded`
        // covers).
        service.setPending("ideas", enabled: false)
        #expect(service.pending == ["ideas": false])
    }

    @Test("discardPending() clears the staged changes AND the cascade consent collected for them")
    func discardPendingClearsBoth() async {
        let (service, _) = Self.makeService(stdout: Self.featuresListJSON)
        await service.load()

        service.setPending("ideas", enabled: false)
        service.applyWithDependents = ["ideas"]

        service.discardPending()

        #expect(service.pending.isEmpty)
        #expect(service.applyWithDependents.isEmpty, "consent for a disable that is no longer staged must not survive")
    }

    // MARK: - dependents(of:)

    @Test("dependents(of:) decodes the dry-run cascade preview")
    func dependentsDecodes() async {
        let (service, runner) = Self.makeService(stdout: Self.dependentsJSON)
        let deps = await service.dependents(of: "memory")

        #expect(runner.invocations == [["features", "disable", "memory", "--dry-run", "--json"]])
        #expect(deps?.map(\.id) == ["briefing", "day-plan"])
        #expect(deps?.map(\.title) == ["Daily Briefing", "Day Plan"])
        #expect(service.loadError == nil)
    }

    @Test("dependents(of:) decodes an empty cascade as an empty list, not nil")
    func dependentsDecodesEmptyList() async {
        // The Go side always marshals `[]`, never null, for a leaf feature —
        // the caller stages the disable directly on this, so it must stay
        // distinguishable from the failure case below.
        let (service, _) = Self.makeService(stdout: #"{"feature":"briefing","dependents":[]}"#)
        let deps = await service.dependents(of: "briefing")

        #expect(deps?.isEmpty == true)
        #expect(service.loadError == nil)
    }

    @Test("dependents(of:) returns nil on a CLI failure, so the caller can tell it apart from an empty cascade")
    func dependentsSurfacesFailure() async {
        let (service, _) = Self.makeService(
            stdout: "",
            error: CLIRunnerError.nonZeroExit(code: 1, stderr: "boom: unknown feature")
        )
        let deps = await service.dependents(of: "nope")

        #expect(deps == nil, "an empty list would read as \"asked, and there are none\" and stage the disable")
        #expect(service.loadError?.contains("boom: unknown feature") == true)
        #expect(service.pending.isEmpty, "a failed preview must stage nothing")
    }

    // MARK: - apply() — degenerate no-op
    //
    // A loop/batch whose "clean exit" is doing nothing is the recurring spot
    // where coverage is skipped in favor of the happy and explicit-error
    // paths — assert it directly rather than assuming it from the others.

    @Test("apply() with no pending changes is a clean no-op: no CLI calls, no restart")
    func applyNoOpWhenPendingEmpty() async {
        let (service, runner) = Self.makeService(stdout: Self.featuresListJSON)
        let spy = RestartSpy()

        await service.apply { await spy.restart() }

        #expect(runner.invocations.isEmpty)
        #expect(spy.callCount == 0)
        #expect(service.isApplying == false)
    }

    // MARK: - apply() — dispatch + ordering

    @Test("apply() routes a feature id through features enable/disable and a sub-toggle key through config set, in sorted order")
    func applyDispatchesByKeyKind() async {
        let (service, runner) = Self.makeService(stdout: Self.featuresListJSON)
        await service.load()

        service.setPending("memory.semantic.enabled", enabled: true)
        service.setPending("ideas", enabled: false)
        let spy = RestartSpy()

        await service.apply { await spy.restart() }

        // "ideas" sorts before "memory.semantic.enabled" — deterministic order,
        // independent of Dictionary's own (unordered) iteration order.
        let cliCalls = runner.invocations.filter { $0 != ["features", "list", "--json"] }
        #expect(cliCalls == [
            ["features", "disable", "ideas"],
            ["config", "set", "memory.semantic.enabled", "true"]
        ])
        #expect(service.pending.isEmpty)
        #expect(service.loadError == nil)
    }

    @Test("apply() passes --with-dependents on a disable whose id is in applyWithDependents")
    func applyPassesWithDependentsOnMarkedDisable() async {
        let (service, runner) = Self.makeService(stdout: Self.featuresListJSON)
        await service.load()

        // "ideas" rather than "memory": setPending drops an entry matching the
        // loaded state, and the fixture already has "memory" disabled, so
        // staging a disable on it would stage nothing. Only a feature that is
        // actually on can be disabled, with or without dependents.
        service.setPending("ideas", enabled: false)
        service.applyWithDependents = ["ideas"]
        let spy = RestartSpy()
        await service.apply { await spy.restart() }

        let cliCalls = runner.invocations.filter { $0 != ["features", "list", "--json"] }
        #expect(cliCalls == [["features", "disable", "ideas", "--with-dependents"]])
        #expect(service.applyWithDependents.isEmpty, "consumed by apply(), must not leak into the next batch")
    }

    @Test("apply() never passes --with-dependents on enable, even with a stale applyWithDependents entry")
    func applyNeverPassesWithDependentsOnEnable() async {
        // The Go CLI's `features enable` has no --with-dependents flag at
        // all (only `disable` registers it) — cobra would reject the call
        // outright, so a leftover flag from an earlier disable attempt must
        // never leak onto an enable call.
        let (service, runner) = Self.makeService(stdout: Self.featuresListJSON)
        await service.load()

        service.setPending("memory", enabled: true)
        service.applyWithDependents = ["memory"]
        let spy = RestartSpy()
        await service.apply { await spy.restart() }

        let cliCalls = runner.invocations.filter { $0 != ["features", "list", "--json"] }
        #expect(cliCalls == [["features", "enable", "memory"]])
    }

    // MARK: - apply() — restart + reload sequencing

    @Test("apply() calls restart exactly once and reloads after every CLI call succeeds")
    func applyRestartsAndReloadsOnSuccess() async {
        let (service, runner) = Self.makeService(stdout: Self.featuresListJSON)
        await service.load()

        service.setPending("ideas", enabled: false)
        let spy = RestartSpy()
        await service.apply { await spy.restart() }

        #expect(spy.callCount == 1)
        // The initial load() above, then apply()'s one CLI call, then
        // apply()'s own trailing reload.
        #expect(runner.invocations == [
            ["features", "list", "--json"],
            ["features", "disable", "ideas"],
            ["features", "list", "--json"]
        ])
        #expect(service.features.count == 4, "apply() reloaded from the (fake) CLI")
        #expect(service.isApplying == false)
    }

    // MARK: - onDisabledChanged

    @Test("load() invokes onDisabledChanged with the freshly computed disabled set on success")
    func loadInvokesOnDisabledChanged() async {
        let (service, _) = Self.makeService(stdout: Self.featuresListJSON)
        var received: Set<String>?
        service.onDisabledChanged = { received = $0 }

        await service.load()

        #expect(received == ["tracks", "memory"])
    }

    @Test("load() folds an already-staged pending change into the onDisabledChanged payload")
    func loadInvokesOnDisabledChangedWithPendingFolded() async {
        let (service, _) = Self.makeService(stdout: Self.featuresListJSON)
        service.setPending("ideas", enabled: false)
        var received: Set<String>?
        service.onDisabledChanged = { received = $0 }

        await service.load()

        #expect(received == ["tracks", "memory", "ideas"])
    }

    @Test("load() failure does not invoke onDisabledChanged")
    func loadFailureDoesNotInvokeOnDisabledChanged() async {
        let (service, _) = Self.makeService(
            stdout: "",
            error: CLIRunnerError.nonZeroExit(code: 1, stderr: "boom")
        )
        var invoked = false
        service.onDisabledChanged = { _ in invoked = true }

        await service.load()

        #expect(invoked == false)
    }

    @Test("apply() invokes onDisabledChanged exactly once, via its trailing load(), on full success")
    func applyInvokesOnDisabledChangedViaTrailingLoad() async {
        let (service, _) = Self.makeService(stdout: Self.featuresListJSON)
        await service.load()

        service.setPending("ideas", enabled: false)
        var callCount = 0
        service.onDisabledChanged = { _ in callCount += 1 }
        let spy = RestartSpy()

        await service.apply { await spy.restart() }

        #expect(callCount == 1)
    }

    // MARK: - apply() — stops on first failure

    @Test("apply() stops on the first failed call, restarts once because something did apply, reloads, and still reports the failure")
    func applyStopsOnFirstFailure() async throws {
        // failOnCall: 3 — call #1 is the seed load() below, #2 is "ideas"
        // (sorts first, succeeds), #3 is "tracks" (sorts second, fails).
        // Call #4 is apply()'s trailing reload, run after the failure.
        let runner = NthCallFailingRunner(
            failOnCall: 3,
            error: CLIRunnerError.nonZeroExit(code: 1, stderr: "boom: disable failed"),
            stdout: Data(Self.featuresListJSON.utf8),
            stdoutAfterFailure: Data(Self.featuresListAfterIdeasDisabledJSON.utf8)
        )
        let service = FeatureManagerService(runner: runner)
        await service.load()

        service.setPending("ideas", enabled: false)
        service.setPending("tracks", enabled: true)
        let spy = RestartSpy()

        await service.apply { await spy.restart() }

        #expect(runner.invocations == [
            ["features", "list", "--json"],
            ["features", "disable", "ideas"],
            ["features", "enable", "tracks"],
            ["features", "list", "--json"]
        ])
        #expect(
            service.pending == ["tracks": true],
            "\"ideas\" already succeeded and is no longer pending; \"tracks\" failed and stays pending for retry"
        )
        #expect(
            service.loadError?.contains("boom: disable failed") == true,
            "the apply failure must survive the trailing successful reload, not get silently cleared by it"
        )
        #expect(spy.callCount == 1, "\"ideas\" already went live before the failure — restart must fire so it actually stops now")
        #expect(service.isApplying == false)

        // The trailing reload is not a no-op: `features` (and therefore
        // disabledFeatureIDs) reflect the post-failure reality, not the
        // stale pre-apply snapshot.
        let ideas = try #require(service.features.first { $0.id == "ideas" })
        #expect(ideas.state == "disabled")
        #expect(service.disabledFeatureIDs.contains("ideas") == true, "ideas is disabled and no longer pending, so this comes from the reload")
        #expect(
            service.disabledFeatureIDs.contains("tracks") == false,
            "tracks' failed enable is still staged in pending, which folds to \"not disabled\" per the documented contract"
        )
    }

    @Test("apply() does not restart when the very first call fails outright, but still reloads")
    func applyDoesNotRestartWhenNothingApplied() async {
        // failOnCall: 2 — call #1 is the seed load() below, #2 is the one
        // pending change's only CLI call, which fails immediately: nothing
        // ever went live. Call #3 is apply()'s trailing reload.
        let runner = NthCallFailingRunner(
            failOnCall: 2,
            error: CLIRunnerError.nonZeroExit(code: 1, stderr: "boom: disable failed"),
            stdout: Data(Self.featuresListJSON.utf8)
        )
        let service = FeatureManagerService(runner: runner)
        await service.load()

        service.setPending("ideas", enabled: false)
        let spy = RestartSpy()

        await service.apply { await spy.restart() }

        #expect(runner.invocations == [
            ["features", "list", "--json"],
            ["features", "disable", "ideas"],
            ["features", "list", "--json"]
        ])
        #expect(service.pending == ["ideas": false], "nothing applied — the only pending entry stays pending for retry")
        #expect(spy.callCount == 0, "nothing went live — no reason to restart the daemon")
        #expect(service.loadError?.contains("boom: disable failed") == true)
        #expect(service.isApplying == false)
    }
}

// MARK: - NthCallFailingRunner

/// Succeeds on every call except the `failOnCall`-th (1-indexed, counting
/// every call this instance ever receives) — models a batch where an
/// earlier CLI call has already gone through by the time a later one fails.
/// `FakeCLIRunner` only supports "always succeed" or "always throw", which
/// can't express a partial-success batch. Calls after the failure (e.g.
/// apply()'s trailing reload) return `stdoutAfterFailure` instead of
/// `stdout`, so a test can hand back an already-updated fixture — modeling
/// what the real CLI would report once the calls before the failure have
/// actually taken effect.
private final class NthCallFailingRunner: CLIRunnerProtocol {
    private let failOnCall: Int
    private let error: Error
    private let stdout: Data
    private let stdoutAfterFailure: Data
    private(set) var invocations: [[String]] = []

    init(failOnCall: Int, error: Error, stdout: Data, stdoutAfterFailure: Data? = nil) {
        self.failOnCall = failOnCall
        self.error = error
        self.stdout = stdout
        self.stdoutAfterFailure = stdoutAfterFailure ?? stdout
    }

    func run(args: [String]) async throws -> Data {
        invocations.append(args)
        let callNumber = invocations.count
        if callNumber == failOnCall {
            throw error
        }
        return callNumber > failOnCall ? stdoutAfterFailure : stdout
    }
}

// MARK: - RestartSpy

/// Records how many times the injected `restart` closure fired.
@MainActor
private final class RestartSpy {
    private(set) var callCount = 0
    func restart() async { callCount += 1 }
}

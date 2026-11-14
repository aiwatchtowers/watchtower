import XCTest
@testable import WatchtowerCore

/// The Analytics → Context "Do these" list (context actions, spec part 4 and
/// the failure paths table): each row's saving, tag, evidence, verb, state
/// and the buttons the state allows.
final class ContextActionsPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private typealias Row = ContextActionRow

    private func stamp(daysAgo: Double) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(-daysAgo * 24 * 3600))
    }

    private func proposal(
        _ id: Int64,
        destination: String = "claude_plugin_off",
        workbench: Int64 = 0,
        status: String = "open",
        source: String = "acme-tools@example-market",
        origin: String = "context",
        decidedDaysAgo: Double? = nil,
        baseline: Double? = nil,
        verdict: String = "",
        verdictValue: Double? = nil,
        verdictDaysAgo: Double? = nil,
        evidence: [CoachEvidence] = [],
        session: Int64? = nil,
        viaSession: Bool = false,
        branch: String = "",
        pr: Int64? = nil,
        prState: String? = nil,
        prURL: String? = nil,
        measureFromDaysAgo: Double? = nil
    ) -> CoachProposal {
        var p = CoachProposal(
            id: id, title: "Proposal \(id)", why: "w", destination: destination, workbenchID: workbench, promptID: "",
            kind: destination.hasPrefix("repo_") || destination == "claude_memory_index" ? "restructure" : "cut",
            metric: "start_tokens", before: "true", after: "false", evidence: evidence, sources: 6, status: status,
            createdAt: stamp(daysAgo: 20), decidedAt: decidedDaysAgo.map { stamp(daysAgo: $0) }, baseline: baseline,
            verdict: verdict, verdictValue: verdictValue, verdictAt: verdictDaysAgo.map { stamp(daysAgo: $0) },
            revertsID: 0, budget: 0)
        p.origin = origin
        p.sourceKey = source
        p.sessionID = session
        p.viaSession = viaSession
        p.sessionBranch = branch
        p.pr = pr
        p.prState = prState
        p.prURL = prURL
        p.measureFrom = measureFromDaysAgo.map { stamp(daysAgo: $0) }
        return p
    }

    /// An accepted repository row started through a session.
    private func repoRow(
        _ id: Int64 = 50,
        session: Int64? = 41,
        branch: String = "wt/slim",
        pr: Int64? = nil,
        prState: String? = nil,
        prURL: String? = nil,
        destination: String = "repo_claude_md"
    ) -> CoachProposal {
        proposal(id, destination: destination, workbench: 3, status: "accepted", source: "", decidedDaysAgo: 1,
                 baseline: 60000, session: session, viaSession: true, branch: branch, pr: pr, prState: prState,
                 prURL: prURL)
    }

    private func source(_ group: String, _ kind: String, tokens: Int, part: String = "skills", measured: Int = 6)
        -> AgentSourceGroupRow {
        AgentSourceGroupRow(part: part, group: group, groupKind: kind, tokens: tokens, calls: 0,
                            measuredSessions: measured)
    }

    private func rows(
        _ ps: [CoachProposal],
        workbench: Int64 = 3,
        sources: [AgentSourceGroupRow] = [],
        kinds: [Int64: SessionSwitcherPresentation.State.Kind] = [:],
        linkFailed: [Int64: Int64] = [:],
        repository: URL? = nil
    ) -> (doThese: [Row], done: [Row]) {
        ContextActionsPresentation.rows(proposals: ps, workbenchID: workbench, sources: sources,
                                        sessionKinds: kinds, linkFailed: linkFailed, now: now,
                                        repository: repository)
    }

    private func only(
        _ p: CoachProposal,
        kinds: [Int64: SessionSwitcherPresentation.State.Kind] = [:],
        linkFailed: [Int64: Int64] = [:],
        repository: URL? = nil
    ) throws -> Row {
        let out = rows([p], kinds: kinds, linkFailed: linkFailed, repository: repository)
        return try XCTUnwrap((out.doThese + out.done).first)
    }

    // MARK: - Order, reach and filtering

    func testRowsOrderedBySaving() {
        let sources = [
            source("acme-tools", "plugin", tokens: 1400),
            source("plugin_acme-tools_files", "mcp_server", tokens: 300, part: "tools"),
            source("example-server", "mcp_server", tokens: 4100, part: "tools"),
            source("claude.ai", "claude_ai_connectors", tokens: 2000, part: "tools"),
            source("claude.ai", "claude_ai_connectors", tokens: 900, part: "tools", measured: 0)
        ]
        let out = rows([
            proposal(1),
            proposal(2, destination: "claude_mcp_server_off", source: "example-server"),
            proposal(3, destination: "repo_claude_md", workbench: 3, source: ""),
            proposal(4, destination: "claude_connectors_off", source: "connectors"),
            // Accepted and working: after every open row, whatever it saves.
            proposal(5, destination: "claude_mcp_server_off", workbench: 3, status: "accepted",
                     source: "example-server", decidedDaysAgo: 1, verdict: "reverted_outside")
        ], sources: sources)
        XCTAssertEqual(out.doThese.map(\.proposal.id), [2, 4, 1, 3, 5])
        // A plugin weighs its own servers too; rows never measured add nothing.
        XCTAssertEqual(out.doThese.map(\.saving), [4100, 2000, 1700, nil, 4100])
        XCTAssertEqual(out.doThese[0].savingText, "−4.1k")
        XCTAssertEqual(out.doThese.map(\.tag), [.settings, .settings, .settings, .repoPR, .settings])
        XCTAssertEqual(out.doThese.prefix(4).map(\.verb), [.turnOff, .turnOff, .turnOff, .accept])
        XCTAssertEqual(out.doThese[0].actions, [.turnOff, .decline])
    }

    /// A global row's saving is its group's weight in this workbench's
    /// sources; absent there, no number.
    func testGlobalRowSavingIsThisWorkbenchsWeight() {
        let here = rows([proposal(1)], sources: [source("acme-tools", "plugin", tokens: 900)])
        XCTAssertEqual(here.doThese.first?.saving, 900)
        let absent = rows([proposal(1)], sources: [source("other-plugin", "plugin", tokens: 900)])
        XCTAssertNil(absent.doThese.first?.saving)
        XCTAssertNil(absent.doThese.first?.savingText)
    }

    func testPluginServersGoToTheLongestPluginMatch() {
        let sources = [
            source("acme", "plugin", tokens: 600),
            source("acme_tools", "plugin", tokens: 700),
            source("plugin_acme_tools_files", "mcp_server", tokens: 500, part: "tools")
        ]
        let out = rows([proposal(1, source: "acme@example-market"), proposal(2, source: "acme_tools@example-market")],
                       sources: sources)
        XCTAssertEqual(out.doThese.map(\.saving), [1200, 600])
    }

    func testGlobalRowsShownInEveryWorkbench() {
        let ps = [proposal(1), proposal(2, destination: "repo_claude_md", workbench: 5, source: ""),
                  proposal(3, destination: "claude_memory_index", workbench: 3, source: "memory")]
        XCTAssertEqual(Set(rows(ps, workbench: 3).doThese.map(\.proposal.id)), [1, 3])
        XCTAssertEqual(Set(rows(ps, workbench: 5).doThese.map(\.proposal.id)), [1, 2])
    }

    func testOnlyContextRowsAndNeverDeclinedOnes() {
        let ps = [proposal(1, origin: "weekly"), proposal(2, origin: "chat"), proposal(3, status: "declined"),
                  proposal(4, status: "rolled_back", decidedDaysAgo: 1), proposal(5)]
        let out = rows(ps)
        XCTAssertEqual((out.doThese + out.done).map(\.proposal.id), [5])
    }

    // MARK: - Evidence

    func testElsewhereEvidenceLine() throws {
        let p = proposal(1, evidence: [
            CoachEvidence(kind: "source", ref: "acme-tools · 1400 tok · 0 calls in Watchtower sessions (all workbenches) in 30 days"),
            CoachEvidence(kind: "elsewhere", ref: "on in: app-one, app-two")
        ])
        XCTAssertEqual(try only(p).evidence,
                       "0 calls in Watchtower sessions (all workbenches) in 30 days · Also on in: app-one, app-two")
        XCTAssertEqual(try only(proposal(2)).evidence, "0 calls in Watchtower sessions (all workbenches) in 30 days")

        let repo = proposal(3, destination: "repo_claude_md", workbench: 3, source: "", evidence: [
            CoachEvidence(kind: "file", ref: "CLAUDE.md · 74.0 KB"),
            CoachEvidence(kind: "section", ref: "Feature Notes · 30.0 KB")
        ])
        XCTAssertEqual(try only(repo).evidence, "CLAUDE.md · 74.0 KB · Feature Notes · 30.0 KB")
        let memory = try only(proposal(4, destination: "claude_memory_index", workbench: 3, source: "memory"))
        XCTAssertEqual(memory.tag, .memory)
        XCTAssertEqual(memory.verb, .archive)
        XCTAssertEqual(memory.actions, [.archive, .decline])
    }

    // MARK: - Session states

    func testWorkingUntilSessionEnds() throws {
        let live: [SessionSwitcherPresentation.State.Kind] = [
            .running, .working, .needsApproval, .waitingOnAsk, .background, .readyToCheck
        ]
        for kind in live {
            let row = try only(repoRow(), kinds: [41: kind])
            XCTAssertEqual(row.state, .working(41), "\(kind)")
            XCTAssertEqual(row.actions, [.openSession])
            XCTAssertNil(row.stateLine)
        }
        XCTAssertEqual(try only(repoRow(), kinds: [41: .finished]).state, .endedWithoutChange(41))
        XCTAssertEqual(try only(repoRow(), kinds: [41: .failed]).state, .endedWithoutChange(41))
    }

    /// A session closed or crashed before its first turn has kind
    /// `.notStarted` once it is no longer live: ended, never working forever.
    func testCrashedSessionIsNotWorking() throws {
        let row = try only(repoRow(), kinds: [41: .notStarted])
        XCTAssertEqual(row.state, .endedWithoutChange(41))
        XCTAssertEqual(row.actions, [.openSession, .startAgain, .dismiss])
        XCTAssertEqual(row.stateLine, "Session ended without a PR")
        let memory = try only(repoRow(destination: "claude_memory_index"), kinds: [41: .notStarted])
        XCTAssertEqual(memory.stateLine, "Session ended without a change")
    }

    /// Right after Accept (or Start Again) the caller keeps the id in
    /// `starting` until the session is live: that wins over any kind.
    func testStartingWinsUntilLive() {
        func state(_ kinds: [Int64: SessionSwitcherPresentation.State.Kind], _ p: CoachProposal) -> Row.State? {
            ContextActionsPresentation.rows(proposals: [p], workbenchID: 3, sources: [], sessionKinds: kinds,
                                            linkFailed: [:], now: now, starting: [50]).doThese.first?.state
        }
        for kind: SessionSwitcherPresentation.State.Kind in [.notStarted, .stopped, .finished, .working] {
            XCTAssertEqual(state([41: kind], repoRow()), .starting, "\(kind)")
        }
        // No session row yet, or none at all: still starting, never gone.
        XCTAssertEqual(state([:], repoRow()), .starting)
        XCTAssertEqual(state([:], repoRow(session: nil, branch: "")), .starting)
        // Once the caller drops the id, the kind decides.
        let live = rows([repoRow()], kinds: [41: .working]).doThese.first
        XCTAssertEqual(live?.state, .working(41))
        // An accepted row being started again is not an open change.
        let again = ContextActionsPresentation.rows(proposals: [repoRow()], workbenchID: 3, sources: [],
                                                    sessionKinds: [:], linkFailed: [:], now: now, starting: [50])
        XCTAssertEqual(again.doThese.first?.isOpen, false)
        XCTAssertEqual(again.doThese.first?.actions, [])
    }

    func testEndedWithoutPR() throws {
        for kind: SessionSwitcherPresentation.State.Kind in [.stopped, .finished] {
            let row = try only(repoRow(), kinds: [41: kind])
            XCTAssertEqual(row.state, .endedWithoutChange(41))
            XCTAssertEqual(row.stateLine, "Session ended without a PR")
            let memory = try only(repoRow(destination: "claude_memory_index"), kinds: [41: kind])
            XCTAssertEqual(memory.state, .endedWithoutChange(41))
            XCTAssertEqual(memory.stateLine, "Session ended without a change")
        }
    }

    func testEndedWithoutPROffersStartAgainAndDismiss() throws {
        let row = try only(repoRow(), kinds: [41: .stopped])
        XCTAssertEqual(row.actions, [.openSession, .startAgain, .dismiss])
        XCTAssertFalse(row.actions.contains(.decline), "Decline is only for open rows")
        // The session row is gone but its branch is known: a PR would still be
        // found, so Start Again is safe; there is no session to open.
        let gone = try only(repoRow(session: nil, branch: "wt/slim"))
        XCTAssertEqual(gone.state, .endedWithoutChange(nil))
        XCTAssertEqual(gone.actions, [.startAgain, .dismiss])
        // A memory session whose row is gone ended without a change: no PR to trace.
        let memory = try only(repoRow(session: nil, branch: "", destination: "claude_memory_index"))
        XCTAssertEqual(memory.state, .endedWithoutChange(nil))
    }

    func testSessionGoneWithoutBranchOffersDismissOnly() throws {
        let row = try only(repoRow(session: nil, branch: ""))
        XCTAssertEqual(row.state, .sessionGone)
        XCTAssertEqual(row.actions, [.dismiss])
        XCTAssertEqual(row.stateLine, "Session was removed — its PR can't be traced")
        // A session id the Desktop no longer has a row for counts as gone too.
        XCTAssertEqual(try only(repoRow(session: 41, branch: "")).state, .sessionGone)
    }

    func testSessionRowGoneWithPRIsPRReady() throws {
        let repo = try XCTUnwrap(URL(string: "https://github.com/acme/app"))
        let row = try only(repoRow(session: nil, branch: "", pr: 17, prState: "open"), repository: repo)
        XCTAssertEqual(row.state, .prReady(pr: 17, url: URL(string: "https://github.com/acme/app/pull/17")))
        XCTAssertEqual(row.actions, [.openPR, .showDiff])
        // The PR decides first: a finished session with a PR is ready, not ended.
        let finished = try only(repoRow(pr: 17, prState: "open"), kinds: [41: .finished])
        XCTAssertEqual(finished.state, .prReady(pr: 17, url: nil))
        XCTAssertFalse(finished.actions.contains(.startAgain))
    }

    func testPRReadyHasDiffURL() throws {
        let row = try only(repoRow(pr: 17, prState: "open", prURL: "https://github.com/acme/app/pull/17"),
                           kinds: [41: .working])
        XCTAssertEqual(row.prLink, URL(string: "https://github.com/acme/app/pull/17"))
        XCTAssertEqual(row.diffURL, URL(string: "https://github.com/acme/app/pull/17/files"))
        XCTAssertNil(try only(repoRow(pr: 17, prState: "open")).diffURL, "no link and no repository")
    }

    func testMergedIsMeasuringAndClosedIsNotMerged() throws {
        let merged = rows([repoRow(pr: 17, prState: "merged")])
        XCTAssertEqual(merged.done.map(\.state), [.measuring])
        XCTAssertTrue(merged.doThese.isEmpty)
        let closed = try only(repoRow(pr: 17, prState: "closed"))
        XCTAssertEqual(closed.state, .notMerged)
        XCTAssertEqual(closed.stateLine, "Not merged")
        XCTAssertEqual(closed.actions, [])
    }

    /// Task 9 fix round: a CLAUDE.md move carries the proposer's estimate
    /// (`saving_tokens` evidence): shown as "−~18.5k", counted in the
    /// headline, kept out of the evidence line. The memory index has none.
    func testRepoSavingEstimateFromEvidence() throws {
        let estimate = CoachEvidence(kind: "saving_tokens", ref: "18500")
        let size = CoachEvidence(kind: "file", ref: "Feature Notes is 60 of 80 KB")
        let repo = proposal(7, destination: "repo_claude_md", workbench: 3, source: "", evidence: [size, estimate])
        let memory = proposal(8, destination: "claude_memory_index", workbench: 3, source: "", evidence: [estimate])
        let out = rows([repo, memory])
        let byID = Dictionary(uniqueKeysWithValues: out.doThese.map { ($0.id, $0) })
        XCTAssertEqual(byID[7]?.saving, 18500)
        XCTAssertEqual(byID[7]?.savingText, "−~18.5k", "minus, then about")
        XCTAssertEqual(byID[7]?.evidence, "Feature Notes is 60 of 80 KB")
        XCTAssertNil(byID[8]?.saving)
        XCTAssertEqual(out.doThese.first?.id, 7, "largest saving first")
        XCTAssertEqual(ContextActionsPresentation.headline(baselineTokens: 60000, rows: out.doThese),
                       "1 change would cut it to ~42k")
    }

    /// Task 9 fix round 2: a revert session that ended (the same ended
    /// kinds) with no revert PR offers Revert… again, its session still
    /// openable; while it runs, or before it is live, the row stays reverting.
    func testEndedRevertSessionOffersRevertAgain() throws {
        let merged = repoRow(pr: 17, prState: "merged")
        func state(_ kinds: [Int64: SessionSwitcherPresentation.State.Kind], starting: Set<Int64> = []) throws -> Row {
            try XCTUnwrap(ContextActionsPresentation.row(of: merged, sessionKinds: kinds, linkFailed: [:],
                                                         starting: starting, revertSessions: [50: 44]))
        }
        for kind in [SessionSwitcherPresentation.State.Kind.stopped, .finished, .failed, .notStarted] {
            let ended = try state([44: kind])
            XCTAssertEqual(ended.state, .revertEnded(44), "\(kind)")
            XCTAssertEqual(ended.actions, [.openSession, .revert])
            XCTAssertEqual(ended.stateLine, "Revert session ended without a PR")
        }
        XCTAssertEqual(try state([44: .working]).state, .reverting(44))
        XCTAssertEqual(try state([44: .notStarted], starting: [50]).state, .reverting(44), "not live yet")
        XCTAssertEqual(try state([:]).state, .reverting(44), "an unknown row is pruned elsewhere, never offered again")
    }

    /// Task 9: a merged repository change is reverted through a session
    /// (**Revert…**); a written memory index is rolled back from its stored
    /// copy (**Undo**); an unmerged or unwritten one offers neither.
    func testMergedRepoRowRevertsAndWrittenMemoryUndoes() throws {
        let merged = try only(repoRow(pr: 17, prState: "merged"))
        XCTAssertEqual(merged.actions, [.revert])
        XCTAssertEqual(ContextActionRow.Action.revert.title, "Revert…")
        var memory = repoRow(destination: "claude_memory_index")
        memory.measureFrom = stamp(daysAgo: 1)
        let written = try only(memory)
        XCTAssertEqual(written.state, .measuring)
        XCTAssertEqual(written.actions, [.undo])
        XCTAssertEqual(try only(repoRow(pr: 17, prState: "closed")).actions, [])
    }

    func testLinkFailedRow() throws {
        let row = try only(proposal(7, destination: "repo_claude_md", workbench: 3, source: ""), linkFailed: [7: 41])
        XCTAssertEqual(row.state, .linkFailed(41))
        XCTAssertEqual(row.stateLine, "Session is running, but Watchtower could not link it")
        XCTAssertEqual(row.actions, [.openSession, .retryLink])
        XCTAssertFalse(row.actions.contains(.accept), "a second session must not start")
    }

    func testStartingAndFailedStart() {
        let out = ContextActionsPresentation.rows(
            proposals: [proposal(7, destination: "repo_claude_md", workbench: 3, source: ""), proposal(8)],
            workbenchID: 3, sources: [], sessionKinds: [:], linkFailed: [:], now: now,
            starting: [7], errors: [8: "settings.json is not readable"])
        let byID = Dictionary(uniqueKeysWithValues: out.doThese.map { ($0.proposal.id, $0) })
        XCTAssertEqual(byID[7]?.state, .starting)
        XCTAssertEqual(byID[7]?.actions, [])
        XCTAssertEqual(byID[8]?.state, .failed("settings.json is not readable"))
        XCTAssertEqual(byID[8]?.stateLine, "settings.json is not readable")
        XCTAssertEqual(byID[8]?.actions, [.turnOff, .decline])
    }

    // MARK: - Settings lifecycle

    func testDoneShowsBeforeAfter() throws {
        let measuring = rows([proposal(1, status: "accepted", decidedDaysAgo: 1, baseline: 60000)])
        let row = try XCTUnwrap(measuring.done.first)
        XCTAssertTrue(measuring.doThese.isEmpty)
        XCTAssertEqual(row.state, .done(beforeTokens: 60000, afterTokens: nil))
        XCTAssertEqual(row.beforeAfter, "60.0k → measuring")
        XCTAssertEqual(row.stateLine, "Takes effect in new sessions")
        XCTAssertEqual(row.actions, [.undo])

        let works = try only(proposal(1, status: "accepted", decidedDaysAgo: 15, baseline: 60000, verdict: "works",
                                      verdictValue: 40000, verdictDaysAgo: 1))
        XCTAssertEqual(works.state, .done(beforeTokens: 60000, afterTokens: 40000))
        XCTAssertEqual(works.beforeAfter, "60.0k → 40.0k")

        for verdict in ["no_effect", "too_little_data"] {
            let none = try only(proposal(1, status: "accepted", decidedDaysAgo: 15, baseline: 60000,
                                         verdict: verdict, verdictValue: verdict == "no_effect" ? 79000 : nil,
                                         verdictDaysAgo: 1))
            XCTAssertEqual(none.stateLine, "No measurable saving", verdict)
            // A finished verdict never reads "measuring": no arrow at all.
            XCTAssertNil(none.beforeAfter, verdict)
            XCTAssertEqual(none.state, .done(beforeTokens: 60000,
                                             afterTokens: verdict == "no_effect" ? 79000 : nil))
            XCTAssertEqual(none.actions, [.undo])
        }
        // A repository row closed by Dismiss or the 30-day window: the same.
        let dismissed = try only(CoachProposal(copying: repoRow(), verdict: "too_little_data", verdictValue: nil,
                                               verdictAt: stamp(daysAgo: 1)))
        XCTAssertNil(dismissed.beforeAfter)
        XCTAssertEqual(dismissed.stateLine, "No measurable saving")

        // A repository row measured after its merge ends the same way: no
        // Undo, Revert… (a session's revert PR) instead.
        var repo = repoRow(pr: 17, prState: "merged")
        repo.measureFrom = stamp(daysAgo: 15)
        let repoDone = try only(CoachProposal(copying: repo, verdict: "works", verdictValue: 40000,
                                              verdictAt: stamp(daysAgo: 1)))
        XCTAssertEqual(repoDone.state, .done(beforeTokens: 60000, afterTokens: 40000))
        XCTAssertEqual(repoDone.actions, [.revert])
    }

    func testSavedLine() throws {
        XCTAssertEqual(ContextActionsPresentation.savedLine(tokens: 25400, starts: 10), "Saved 25.4k on 10 starts")
        var p = proposal(1, status: "accepted", decidedDaysAgo: 15, baseline: 60000, verdict: "works",
                         verdictValue: 40000, verdictDaysAgo: 1)
        // No count of starts: before → after only, no line.
        let unknown = try only(p)
        XCTAssertNil(unknown.stateLine)
        XCTAssertEqual(unknown.beforeAfter, "60.0k → 40.0k")
        // 0 = not judged on any session: no line either.
        p.verdictSessions = 0
        XCTAssertNil(try only(p).stateLine)
        p.verdictSessions = 10
        XCTAssertEqual(try only(p).stateLine, "Saved 20k on 10 starts")
    }

    func testSupersededShowsChangedSince() {
        let out = rows([proposal(1, status: "superseded", decidedDaysAgo: 2)])
        XCTAssertEqual(out.done.map(\.state), [.changedSince])
        XCTAssertEqual(out.done.first?.stateLine, "Changed since — nothing was written")
        XCTAssertEqual(out.done.first?.actions, [])
        XCTAssertTrue(rows([proposal(1, status: "superseded", decidedDaysAgo: 15)]).done.isEmpty)
    }

    func testRevertedOutsideOffersTurnOffAgain() throws {
        let out = rows([proposal(1, status: "accepted", decidedDaysAgo: 3, baseline: 60000,
                                 verdict: "reverted_outside", verdictDaysAgo: 1)])
        let row = try XCTUnwrap(out.doThese.first)
        XCTAssertEqual(row.state, .revertedOutside)
        XCTAssertEqual(row.stateLine, "Turned back on outside Watchtower")
        XCTAssertEqual(row.actions, [.turnOffAgain])
    }

    func testDoneFadesAfter14Days() {
        func done(_ verdictDaysAgo: Double?) -> [Row] {
            rows([proposal(1, status: "accepted", decidedDaysAgo: 30, baseline: 60000,
                           verdict: verdictDaysAgo == nil ? "" : "works", verdictValue: 40000,
                           verdictDaysAgo: verdictDaysAgo)]).done
        }
        XCTAssertEqual(done(13).count, 1)
        XCTAssertTrue(done(15).isEmpty)
        // Still measuring: it stays until its verdict, then 14 days more.
        XCTAssertEqual(done(nil).count, 1)
        // A settings row accepted 2 days ago, still measuring, stays.
        XCTAssertEqual(rows([proposal(1, status: "accepted", decidedDaysAgo: 2)]).done.count, 1)
    }

    // MARK: - Headline

    func testHeadline() {
        let sources = [
            source("acme-tools", "plugin", tokens: 4100),
            source("example-server", "mcp_server", tokens: 2000, part: "tools"),
            source("claude.ai", "claude_ai_connectors", tokens: 1500, part: "tools")
        ]
        let open = rows([proposal(1), proposal(2, destination: "claude_mcp_server_off", source: "example-server"),
                         proposal(3, destination: "claude_connectors_off", source: "connectors"),
                         proposal(4, destination: "repo_claude_md", workbench: 3, source: ""),
                         proposal(5, destination: "claude_mcp_server_off", workbench: 3, status: "accepted",
                                  source: "example-server", decidedDaysAgo: 1, verdict: "reverted_outside")],
                        sources: sources).doThese
        XCTAssertEqual(ContextActionsPresentation.headline(baselineTokens: 60000, rows: open),
                       "3 changes would cut it to ~52k")
        XCTAssertEqual(ContextActionsPresentation.headline(baselineTokens: 60000, rows: Array(open.prefix(1))),
                       "1 change would cut it to ~56k")
        XCTAssertEqual(ContextActionsPresentation.headline(baselineTokens: 60000, rows: []), "")
        XCTAssertEqual(ContextActionsPresentation.headline(baselineTokens: 3000, rows: Array(open.prefix(1))),
                       "1 change would cut it to ~0")
    }

    func testTokens() {
        XCTAssertEqual(ContextActionsPresentation.tokens(512), "512")
        XCTAssertEqual(ContextActionsPresentation.tokens(25400), "25.4k")
        XCTAssertEqual(ContextActionsPresentation.tokens(42000), "42k")
        XCTAssertEqual(ContextActionsPresentation.tokens(1_250_000), "1250k")
    }
}

private extension CoachProposal {
    /// `p` with a verdict, as the daemon writes it.
    init(copying p: CoachProposal, verdict: String, verdictValue: Double?, verdictAt: String?) {
        self = CoachProposal(
            id: p.id, title: p.title, why: p.why, destination: p.destination, workbenchID: p.workbenchID,
            promptID: p.promptID, kind: p.kind, metric: p.metric, before: p.before, after: p.after,
            evidence: p.evidence, sources: p.sources, status: p.status, createdAt: p.createdAt,
            decidedAt: p.decidedAt, baseline: p.baseline, verdict: verdict, verdictValue: verdictValue,
            verdictAt: verdictAt, revertsID: p.revertsID, budget: p.budget, skill: p.skill, origin: p.origin,
            conversationID: p.conversationID, writtenBranch: p.writtenBranch, measureFrom: p.measureFrom,
            folderBranch: p.folderBranch, sessionID: p.sessionID, sourceKey: p.sourceKey,
            viaSession: p.viaSession, sessionBranch: p.sessionBranch, pr: p.pr, prState: p.prState,
            prURL: p.prURL, verdictSessions: p.verdictSessions)
    }
}

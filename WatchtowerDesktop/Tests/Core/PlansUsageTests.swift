import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class PlansUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_610_000)

    private func limit(
        key: String = "quota",
        percent: Double = 40,
        state: String = "safe",
        rate: Double = 0,
        hit: Date? = nil,
        reset: Date? = nil,
        duration: Int? = 300
    ) -> PlanUsageLimit {
        PlanUsageLimit(key: key, label: key, group: "session", percent: percent,
                       resetsAt: reset ?? now.addingTimeInterval(min(7200, Double(duration ?? 300) * 60)), severity: nil,
                       projection: PlanUsageProjection(state: state, hitAt: hit, ratePerHour: rate),
                       windowDurationMinutes: duration)
    }

    private func snapshot(
        _ limits: [PlanUsageLimit],
        provider: PlanUsageProvider = .codex,
        state: String = "ok",
        age: TimeInterval = 0,
        known: Bool = true,
        samples: Bool = true,
        endpoints: Bool = true,
        // A nullable source policy is distinct from either boolean.
        // swiftlint:disable:next discouraged_optional_boolean
        ordinary: Bool? = nil
    ) -> PlanUsageStatus {
        let fetched = now.addingTimeInterval(-age)
        var lines: [String: PlanUsageLine?] = [:]
        var history: [String: [PlanUsageSample]] = [:]
        for limit in limits {
            if endpoints, let reset = limit.resetsAt {
                let willHit = limit.projection.state == "will_hit"
                lines[limit.key] = PlanUsageLine(startAt: fetched, startPercent: limit.percent,
                                                 endAt: willHit ? (limit.projection.hitAt ?? reset) : reset,
                                                 endPercent: willHit ? 100 : limit.percent)
            }
            if samples {
                history[limit.key] = [PlanUsageSample(takenAt: fetched, percent: limit.percent, resetsAt: limit.resetsAt)]
            }
        }
        return PlanUsageStatus(state: state, reason: "", plan: "plus", fetchedAt: fetched, lastError: "",
                               limits: limits, breakdown: [], provider: provider, identityKnown: known,
                               ordinaryUsageAllowed: ordinary,
                               plot: endpoints ? PlanUsagePlot(fetchedAt: fetched, limits: lines) : nil, history: history)
    }

    func testOrderedFreshnessAndIdentityGates() throws {
        let value = limit()
        let cases: [(TimeInterval, String, Bool, String?)] = [
            (900, "ok", true, nil), (901, "ok", true, "stale"),
            (-60, "ok", true, nil), (-61, "ok", true, "clock_skew"),
            (0, "error", false, "stale"), (0, "ok", false, "identity_unknown"),
            (-61, "disabled", false, "disabled")
        ]
        for (age, state, known, expected) in cases {
            let result = try snapshot([value], state: state, age: age, known: known).forecast(for: value, now: now)
            XCTAssertEqual(result.unavailableReason, expected, "\(age),\(state),\(known)")
            XCTAssertEqual(result.drawable, expected == nil)
            XCTAssertEqual(result.line != nil, result.drawable)
        }
    }

    func testWindowRawStateAndSampleGates() throws {
        for state in ["idle", "collecting", "hit"] {
            let value = limit(state: state)
            XCTAssertEqual(try snapshot([value]).forecast(for: value, now: now).unavailableReason, state)
        }
        let unknown = limit(duration: nil)
        XCTAssertEqual(try snapshot([unknown], endpoints: false).forecast(for: unknown, now: now).unavailableReason, "missing_window_duration")
        let expired = limit(reset: now)
        XCTAssertEqual(try snapshot([expired], endpoints: false).forecast(for: expired, now: now).unavailableReason, "reset_expired")
        let value = limit()
        XCTAssertEqual(try snapshot([value], samples: false).forecast(for: value, now: now).unavailableReason, "collecting")
        XCTAssertEqual(try snapshot([value], endpoints: false).forecast(for: value, now: now).unavailableReason, "endpoints_unavailable")
        XCTAssertEqual(try snapshot([value]).forecast(for: value, now: now, enabled: false).unavailableReason, "disabled")
    }

    func testInvalidAndExpiredProjectionNeverDraws() throws {
        for rate in [-1.0, Double.infinity, Double.nan] {
            let value = limit(rate: rate)
            let result = try snapshot([value]).forecast(for: value, now: now)
            XCTAssertEqual(result.unavailableReason, "invalid_projection")
            XCTAssertEqual(result.ratePerHour, 0)
            XCTAssertNil(result.line)
        }
        let expired = limit(rate: 1, hit: now)
        XCTAssertEqual(try snapshot([expired]).forecast(for: expired, now: now).unavailableReason, "prediction_expired")
        let unknown = limit(state: "unknown")
        XCTAssertThrowsError(try snapshot([unknown]).forecast(for: unknown, now: now))
        let contradicted = limit(rate: 1, hit: now.addingTimeInterval(60))
        XCTAssertEqual(try snapshot([contradicted]).forecast(for: contradicted, now: now).unavailableReason, "invalid_projection")
    }

    func testMostRestrictiveAcrossEveryBucketAndStableTies() throws {
        let highest = limit(key: "a", percent: 99)
        let earliest = limit(key: "other-bucket", percent: 10, state: "will_hit", rate: 1,
                             hit: now.addingTimeInterval(600))
        let later = limit(key: "base-bucket", percent: 50, state: "will_hit", rate: 1,
                          hit: now.addingTimeInterval(1200))
        var values = [highest, later, earliest]
        XCTAssertEqual(try PlansPresentation.mostRestrictive(snapshot(values), now: now)?.key, earliest.key)
        let hit = limit(key: "hit", percent: 100, state: "hit")
        values.append(hit)
        XCTAssertEqual(try PlansPresentation.mostRestrictive(snapshot(values), now: now)?.key, hit.key)
        let tied = [limit(key: "z", percent: 90), limit(key: "a", percent: 90)]
        XCTAssertEqual(try PlansPresentation.mostRestrictive(snapshot(tied), now: now)?.key, "a")
        XCTAssertEqual(try PlansPresentation.mostRestrictive(snapshot([highest, earliest], known: false), now: now)?.key, highest.key)
    }

    func testMenuProviderGatesNamesAndAllTrayQuotas() throws {
        let claudeLimit = limit(key: "session", percent: 4)
        let claude = snapshot([claudeLimit], provider: .claude)
        let values = [limit(key: "one", percent: 10), limit(key: "two", percent: 30, duration: 90)]
        let codex = snapshot(values)
        XCTAssertEqual(try PlansPresentation.menuBar(claude: claude, codex: codex, show: true, now: now),
                       "Claude 5h 4% · Codex 90m 30%")
        XCTAssertNil(try PlansPresentation.menuBar(claude: claude, codex: codex, show: false, now: now))
        XCTAssertEqual(try PlansPresentation.tray(codex, now: now).count, 2)
        XCTAssertEqual(try PlansPresentation.menuBar(claude: claude, codex: snapshot(values, age: 901), show: true, now: now), "Claude 5h 4%")
        XCTAssertNil(try PlansPresentation.menuBar(claude: nil, codex: snapshot(values, state: "error", known: false), show: true, now: now))
        XCTAssertEqual(try PlansPresentation.menuBar(claude: nil, codex: snapshot(values, known: false), show: true, now: now), "Codex 90m 30%")
    }

    func testClaudeMenuWarningUsesCurrentForecastEligibility() throws {
        let expired = limit(key: "session", percent: 50, state: "will_hit", rate: 1, hit: now.addingTimeInterval(-60))
        let oldPrediction = snapshot([expired], provider: .claude, age: 120)
        XCTAssertEqual(try oldPrediction.forecast(for: expired, now: now).unavailableReason, "prediction_expired")
        XCTAssertEqual(try PlansPresentation.menuBar(claude: oldPrediction, codex: nil, show: true, now: now), "Claude 5h 50%")
        let actual = limit(key: "session", percent: 80, state: "will_hit", rate: 1, hit: now.addingTimeInterval(-60))
        XCTAssertEqual(try PlansPresentation.menuBar(claude: snapshot([actual], provider: .claude, age: 120),
                                                     codex: nil, show: true, now: now), "⚠︎ Claude 5h 80%")
        let future = limit(key: "session", percent: 50, state: "will_hit", rate: 1, hit: now.addingTimeInterval(60))
        XCTAssertEqual(try PlansPresentation.menuBar(claude: snapshot([future], provider: .claude, age: 120),
                                                     codex: nil, show: true, now: now), "⚠︎ Claude 5h 50%")
    }

    func testCopyForEveryUnavailableReasonAndOperationError() throws {
        let reasons = [
            "disabled": "Plan limits are turned off in Features.",
            "clock_skew": "Check your system clock, then refresh.",
            "stale": "Refresh to update the forecast.",
            "identity_unknown": "Current usage only — account identity is unavailable.",
            "missing_window_duration": "This quota does not provide a window duration.",
            "missing_reset": "Waiting for a reset time.",
            "reset_expired": "This window has reset. Refresh to update.",
            "idle": "Window not started", "collecting": "Collecting data…", "hit": "Limit reached",
            "endpoints_unavailable": "Refresh to load the forecast.",
            "invalid_projection": "Forecast unavailable. Refresh to update.",
            "prediction_expired": "Forecast needs an update"
        ]
        for (reason, expected) in reasons { XCTAssertEqual(PlansPresentation.reasonText(reason), expected, reason) }
        let errors = [
            "cli_missing": "Install Codex, then retry.",
            "unsupported_cli": "Update Codex to read subscription limits, then retry.",
            "unsupported_auth": "Sign in to Codex with a ChatGPT account, then retry.",
            "no_credentials": "Open Codex and sign in, then retry.",
            "feature_disabled": "Plan limits are turned off in Features.",
            "busy": "Another refresh is running. Try again shortly.",
            "timeout": "The refresh timed out. Try again.", "cancelled": "Refresh cancelled.",
            "storage": "Couldn't read saved limits. Retry to reload.",
            "parse": "Couldn't read the subscription response. Retry to update.",
            "network": "Couldn't update Codex limits. Retry to update."
        ]
        XCTAssertEqual(Set(errors.keys), Set(PlansOperationError.codes))
        for (code, expected) in errors { XCTAssertEqual(PlansPresentation.errorText(code, provider: .codex), expected, code) }
        let restricted = try PlansPresentation.card(provider: .codex, status: snapshot([limit()], ordinary: false),
                                                    error: nil, refreshing: false, now: now)
        XCTAssertEqual(restricted.summary, "Codex usage is currently restricted")
        let future = try PlansPresentation.card(provider: .codex, status: snapshot([limit()], age: -60),
                                                error: nil, refreshing: true, now: now)
        XCTAssertEqual(future.freshness, "Updated just now")
        XCTAssertEqual(future.action, "Refreshing…")
        let empty = try PlansPresentation.card(provider: .claude, status: nil, error: nil, refreshing: false, now: now)
        XCTAssertEqual(empty.summary, "No Claude plan data yet. Refresh to load limits.")
        let error = try PlansPresentation.card(provider: .codex, status: nil,
                                               error: PlansOperationError(code: "storage"), refreshing: false, now: now)
        XCTAssertEqual(error.action, "Retry")
        let loading = try PlansPresentation.card(provider: .codex, status: nil, error: nil, refreshing: true, now: now)
        XCTAssertEqual(loading.summary, "Loading Codex limits…")
        let off = try PlansPresentation.card(provider: .codex, status: snapshot([limit()]), error: nil,
                                             refreshing: false, now: now, enabled: false)
        XCTAssertEqual(off.summary, reasons["disabled"])
        XCTAssertTrue(off.isStale)
        XCTAssertTrue(off.limits.isEmpty)
    }

    private func sharedFixture(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("internal/planusage/testdata/\(name)"))
    }

    func testSharedGoPlotAndPublicWireFixture() throws {
        let data = try sharedFixture("projection_v1.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let limitData = try JSONSerialization.data(withJSONObject: XCTUnwrap(object["limit"]))
        let value = try PlanUsageDates.decoder.decode(PlanUsageLimit.self, from: limitData)
        let projectionData = try JSONSerialization.data(withJSONObject: XCTUnwrap(object["projection"]))
        let wire = try PlanUsageDates.decoder.decode(PlansWireProjection.self, from: projectionData)
        let plotData = try JSONSerialization.data(withJSONObject: XCTUnwrap(object["plot_json"]))
        let text = try XCTUnwrap(String(data: plotData, encoding: .utf8))
        let fetched = try XCTUnwrap(wire.line?.startAt)
        let plot = try PlanUsagePlot.decode(text, fetchedAt: fetched, limits: [value])
        let status = PlanUsageStatus(state: "ok", reason: "", plan: "", fetchedAt: fetched, lastError: "",
                                     limits: [value], breakdown: [], plot: plot,
                                     history: [value.key: [PlanUsageSample(takenAt: fetched, percent: 40, resetsAt: value.resetsAt)]])
        XCTAssertEqual(try status.forecast(for: value, now: fetched).line, wire.line)
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: sharedFixture("aggregate_v1.json")) as? [String: Any])
        for value in cases.values {
            let envelope = try PlansEnvelope.decode(JSONSerialization.data(withJSONObject: value))
            XCTAssertFalse(envelope.providers.isEmpty)
        }
        let empty = try PlansEnvelope.decode(JSONSerialization.data(withJSONObject: XCTUnwrap(cases["empty"])))
        XCTAssertEqual(empty.providers.map(\.provider), [.claude, .codex])
    }

    func testMalformedPlotIsDistinctFromLegacyDefault() throws {
        let value = limit()
        XCTAssertNil(try PlanUsagePlot.decode("{}", fetchedAt: now, limits: [value]))
        for text in ["null", "[]", "{", "{\"schema_version\":2}", "{\"schema_version\":1,\"fetched_at\":null,\"limits\":{}}"] {
            XCTAssertThrowsError(try PlanUsagePlot.decode(text, fetchedAt: now, limits: [value]), text)
        }
        let line = PlanUsageLine(startAt: now, startPercent: 40, endAt: now.addingTimeInterval(30), endPercent: 40)
        XCTAssertThrowsError(try line.validate(fetchedAt: now.addingTimeInterval(1), limit: value))
    }

    func testPublicWireRejectsMissingNullableLineAndUnknownError() throws {
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: sharedFixture("aggregate_v1.json")) as? [String: Any])
        var drawable = try XCTUnwrap(cases["drawable"] as? [String: Any])
        var providers = try XCTUnwrap(drawable["providers"] as? [[String: Any]])
        var status = try XCTUnwrap(providers[0]["status"] as? [String: Any])
        var limits = try XCTUnwrap(status["limits"] as? [[String: Any]])
        var projection = try XCTUnwrap(limits[0]["projection"] as? [String: Any])
        projection.removeValue(forKey: "line")
        limits[0]["projection"] = projection
        status["limits"] = limits
        providers[0]["status"] = status
        drawable["providers"] = providers
        XCTAssertThrowsError(try PlansEnvelope.decode(JSONSerialization.data(withJSONObject: drawable)))
        let busy = try JSONSerialization.data(withJSONObject: XCTUnwrap(cases["busy"]))
        let text = try XCTUnwrap(String(data: busy, encoding: .utf8))
        XCTAssertThrowsError(try PlansEnvelope.decode(Data(text.replacingOccurrences(of: "busy", with: "unknown_error").utf8)))
    }
}

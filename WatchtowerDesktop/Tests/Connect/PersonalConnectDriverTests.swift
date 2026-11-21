import XCTest
import GRDB
@testable import WatchtowerDesktop
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The personal connect drivers (agent connect, Task 11) on fake view
/// models: no CLI runs, no wall-clock waits. A fake flow ends only when its
/// test opens the gate.
@MainActor
final class PersonalConnectDriverTests: XCTestCase {

    // MARK: - Secrets

    func testEachSecretKindReachesItsCallOnly() async throws {
        struct Case {
            let kind: String
            let driver: any ConnectServiceDriving
            let calls: () -> [String]
            let received: () -> String?
            let expected: String
        }
        let email = FakeEmailModel()
        let emailDriver = EmailConnectDriver(model: email, policy: Self.open)
        _ = await emailDriver.setFields(["host": "imap.example.com", "username": "me@example.com"])
        let caldav = FakeCalendarModel()
        let caldavDriver = CalendarConnectDriver(model: caldav, policy: Self.open)
        _ = await caldavDriver.setFields(["url": "https://caldav.example.com", "username": "me"])
        let ics = FakeCalendarModel()
        let linear = FakeLinearModel()
        let quick = FakeQuickModel()
        let quickDriver = QuickConnectionConnectDriver(model: quick, policy: Self.open)
        _ = await quickDriver.setFields(["name": "docs", "kind": "http", "url": "https://mcp.example.com", "header": "Authorization"])

        let cases = [
            Case(kind: "imap_password", driver: emailDriver, calls: { email.calls },
                 received: { email.password }, expected: "imap"),
            Case(kind: "caldav_password", driver: caldavDriver, calls: { caldav.calls },
                 received: { caldav.received }, expected: "caldav"),
            Case(kind: "ics_url", driver: CalendarConnectDriver(model: ics, policy: Self.open), calls: { ics.calls },
                 received: { ics.received }, expected: "ics"),
            Case(kind: "linear_api_key", driver: LinearConnectDriver(model: linear, policy: Self.open),
                 calls: { linear.calls }, received: { linear.key }, expected: "apiKey"),
            Case(kind: "mcp_secret", driver: quickDriver, calls: { quick.calls },
                 received: { quick.secretJSON }, expected: "add")
        ]
        for item in cases {
            let secret = "s3cr3t-\(item.kind)-value"
            let result = await item.driver.submitSecret(kind: item.kind, value: secret)
            let data = try XCTUnwrap(try? result.get(), item.kind)
            XCTAssertEqual(item.calls(), [item.expected], item.kind)
            XCTAssertTrue(item.received()?.contains(secret) == true, item.kind)
            XCTAssertFalse((String(bytes: data, encoding: .utf8) ?? "").contains(secret), item.kind)
            let status = try JSONEncoder().encode(await item.driver.status())
            XCTAssertFalse((String(bytes: status, encoding: .utf8) ?? "").contains(secret), item.kind)
            XCTAssertTrue(item.driver.secretKinds.contains(item.kind))
        }
        XCTAssertEqual(quick.secretJSON, #"{"headers":{"Authorization":"s3cr3t-mcp_secret-value"}}"#)
    }

    func testFailedSecretVerbHidesTheValue() async {
        let model = FakeCalendarModel()
        model.failWith = { "caldav add-ics: cannot read https://cal.example.com/private-abc: 404" }
        let driver = CalendarConnectDriver(model: model, policy: Self.open)
        let result = await driver.submitSecret(kind: "ics_url", value: "https://cal.example.com/private-abc")
        guard case let .failure(.failed(message)) = result else { return XCTFail("\(result)") }
        XCTAssertFalse(message.contains("private-abc"))
        XCTAssertTrue(message.hasPrefix("the calendar was not added"))
    }

    func testSetFieldsThenSecretUsesFields() async {
        let model = FakeEmailModel()
        let driver = EmailConnectDriver(model: model, policy: Self.open)
        let set = await driver.setFields([
            "host": "imap.example.com", "port": "1143", "security": "starttls", "username": "me@example.com",
            "folder": "Archive"
        ])
        XCTAssertNoThrow(try set.get())
        _ = await driver.submitSecret(kind: "imap_password", value: "pw")
        XCTAssertEqual(model.imap?.host, "imap.example.com")
        XCTAssertEqual(model.imap?.port, 1143)
        XCTAssertEqual(model.imap?.security, "starttls")
        XCTAssertEqual(model.imap?.username, "me@example.com")
        XCTAssertEqual(model.imap?.folder, "Archive")

        // A field outside the playbook, a bad port, and "none" to a remote host are refused.
        if case .success = await driver.setFields(["password": "x"]) { XCTFail("password is never a field") }
        if case .success = await driver.setFields(["port": "99999"]) { XCTFail("bad port") }
        if case .success = await driver.setFields(["security": "none"]) { XCTFail("cleartext to a remote host") }
        // A secret before the fields it needs is refused before any call.
        let empty = FakeEmailModel()
        let bare = await EmailConnectDriver(model: empty, policy: Self.open).submitSecret(kind: "imap_password", value: "pw")
        guard case .failure(.badArgs) = bare else { return XCTFail("\(bare)") }
        XCTAssertTrue(empty.calls.isEmpty)
    }

    // MARK: - Flows

    func testFlowWaitsThenConnectsAndUnknownFlowFails() async throws {
        let model = FakeGoogleModel()
        let driver = GoogleConnectDriver(model: model, policy: Self.open)
        let flowID = try await driver.start(options: ["scopes": "calendar,gmail"]).get()
        XCTAssertEqual(model.added?.calendar, true)
        XCTAssertEqual(model.added?.gmail, true)
        XCTAssertEqual(model.added?.clientID, "")
        let running = await driver.status()
        XCTAssertEqual(running.flow?.id, flowID)
        let waiting = await driver.wait(flowID: flowID)
        XCTAssertEqual(waiting, .waiting)

        model.newRow = ConnectAccountRow(id: 9, ConnectionAccountState(name: "me@example.com", isOK: true, status: "ok", error: ""))
        model.gate.open()
        await driver.flows.finished(flowID)
        let connected = await driver.wait(flowID: flowID)
        XCTAssertEqual(connected, .connected(account: "me@example.com"))
        let after = await driver.status()
        XCTAssertNil(after.flow)
        let unknown = await driver.wait(flowID: "google-unknown")
        XCTAssertEqual(unknown, .failed(reason: ConnectFlowBook.unknownFlow))
        if case .success = await driver.start(options: ["scopes": "drive"]) { XCTFail("unknown scope") }
        if case .success = await driver.start(options: ["scopes": "calendar", "own_client": "x"]) {
            XCTFail("own client is the own Google project's")
        }
    }

    func testCancelActsOnlyOnTheNamedFlow() async throws {
        let model = FakeGoogleModel()
        let driver = GoogleConnectDriver(model: model, policy: Self.open)
        let flowID = try await driver.start(options: ["scopes": "calendar"]).get()
        await driver.cancel(flowID: "google-other")
        XCTAssertEqual(model.cancels, 0)
        await driver.cancel(flowID: flowID)
        XCTAssertEqual(model.cancels, 1)
        await driver.flows.finished(flowID)
        let outcome = await driver.wait(flowID: flowID)
        XCTAssertEqual(outcome, .failed(reason: ConnectFlowBook.cancelled))
        await driver.cancel(flowID: flowID)  // ended: nothing to cancel
        XCTAssertEqual(model.cancels, 1)
    }

    func testOutlookFlowReportsTheVerbError() async throws {
        let model = FakeEmailModel()
        let driver = EmailConnectDriver(model: model, policy: Self.open)
        if case .success = await driver.start(options: [:]) { XCTFail("only outlook starts a flow") }
        let flowID = try await driver.start(options: ["outlook": "true"]).get()
        model.outlookError = "Login failed (exit 1)"
        model.gate.open()
        await driver.flows.finished(flowID)
        let outcome = await driver.wait(flowID: flowID)
        XCTAssertEqual(outcome, .failed(reason: "Login failed (exit 1)"))
    }

    // MARK: - Jira and Confluence

    func testJiraConfluenceOptionPassesWithConfluence() async throws {
        let model = FakeJiraModel()
        let steps = FakeJiraSteps()
        steps.line = "Confluence: Watchtower picked Docs."
        let driver = JiraConnectDriver(model: model, steps: steps, policy: Self.open, companySlug: Self.acme)
        let flowID = try await driver.start(options: ["with_confluence": "true", "site": "acme.atlassian.net"]).get()
        await model.until { model.added != nil }
        XCTAssertEqual(model.added?.withConfluence, true)
        XCTAssertEqual(model.added?.company, "acme")
        XCTAssertEqual(model.added?.site, "acme.atlassian.net")
        model.gate.open()
        await driver.flows.finished(flowID)
        let outcome = await driver.wait(flowID: flowID)
        XCTAssertEqual(outcome, .connected(account: "acme. Confluence: Watchtower picked Docs."))
        XCTAssertEqual(steps.lineBefore, Set<Int>())

        // The plain Jira start asks no Confluence.
        model.gate = Gate()
        let plain = try await driver.start(options: [:]).get()
        await model.until { model.added?.withConfluence == false }
        XCTAssertNil(model.added?.site)
        model.gate.open()
        await driver.flows.finished(plain)
    }

    func testJiraArgsCarryCompanyAndSite() {
        XCTAssertEqual(
            JiraAccountsViewModel.addArgs(withConfluence: true, company: "acme", site: "acme.atlassian.net"),
            ["jira", "add", "--app-return", "--app-site-picker", "--with-confluence",
             "--company", "acme", "--site", "acme.atlassian.net"])
        XCTAssertEqual(JiraAccountsViewModel.addArgs(), ["jira", "add", "--app-return", "--app-site-picker"])
    }

    func testJiraCompanySlugIsTheAtlassianCompany() {
        let personal = CompanyRef(slug: "mine", name: "Mine", personal: true, vendors: [.google: ""])
        let google = CompanyRef(slug: "g", name: "G", vendors: [.google: "example.com"])
        let acme = CompanyRef(slug: "acme", name: "Acme", vendors: [.atlassian: "https://acme.atlassian.net"])
        let forced = CompanyRef(slug: "corp", name: "Corp", forced: true, vendors: [.atlassian: ""])
        XCTAssertNil(JiraConnectDriver.companySlug([personal, google]))
        XCTAssertEqual(JiraConnectDriver.companySlug([google, acme]), "acme")
        XCTAssertEqual(JiraConnectDriver.companySlug([acme, forced]), "corp")
    }

    func testJiraSiteFieldAnswersTheRunningQuestion() async throws {
        let model = FakeJiraModel()
        let driver = JiraConnectDriver(model: model, steps: FakeJiraSteps(), policy: Self.open, companySlug: Self.noCompany)
        let flowID = try await driver.start(options: [:]).get()
        await model.until { model.added != nil }
        model.siteChoices = [JiraSiteChoice(url: "https://alpha.atlassian.net", name: "alpha"),
                             JiraSiteChoice(url: "https://beta.atlassian.net", name: "beta")]
        let asking = await driver.status()
        XCTAssertTrue(asking.flow?.state.hasPrefix(JiraConnectDriver.siteQuestionState) == true)
        if case .success = await driver.setFields(["site": "gamma.atlassian.net"]) { XCTFail("not a listed site") }
        _ = try await driver.setFields(["site": "beta.atlassian.net"]).get()
        XCTAssertEqual(model.chosenSite?.name, "beta")

        // A site named before the question shows answers it at the next wait.
        model.siteChoices = nil
        model.chosenSite = nil
        _ = try await driver.setFields(["site": "alpha.atlassian.net"]).get()
        XCTAssertNil(model.chosenSite)
        model.siteChoices = [JiraSiteChoice(url: "https://alpha.atlassian.net", name: "alpha")]
        _ = await driver.wait(flowID: flowID)
        XCTAssertEqual(model.chosenSite?.name, "alpha")
        model.gate.open()
        await driver.flows.finished(flowID)
    }

    func testChooseJiraBoardsListsAndSelects() async throws {
        let model = FakeJiraModel()
        model.accounts = [JiraAccount(row: ["id": 1, "site_name": "acme", "enabled": true])]
        let steps = FakeJiraSteps()
        steps.boards = [Self.board(1, 10, selected: false), Self.board(1, 20, selected: true)]
        let driver = JiraConnectDriver(model: model, steps: steps, policy: Self.open, companySlug: Self.noCompany)

        let listed = try await driver.choose(kind: "jira_boards", select: nil).get()
        XCTAssertEqual(listed.map(\.id), ["1:10", "1:20"])
        XCTAssertEqual(listed.map(\.selected), [false, true])
        XCTAssertEqual(steps.fetchedSites, [[1]])

        let picked = try await driver.choose(kind: "jira_boards", select: ["1:10"]).get()
        XCTAssertEqual(picked.map(\.selected), [true, false])
        XCTAssertEqual(steps.saved, [["jira", "--account", "1", "boards", "select", "10"],
                                     ["jira", "--account", "1", "boards", "deselect", "20"]])
        if case .success = await driver.choose(kind: "jira_boards", select: ["9:99"]) { XCTFail("unknown board") }
        if case .success = await driver.choose(kind: "linear_teams", select: nil) { XCTFail("not a Jira kind") }
    }

    func testChooseConfluenceSpacesAddsOnlyNewPicks() async throws {
        let model = FakeJiraModel()
        model.accounts = [JiraAccount(row: ["id": 3, "site_name": "acme", "enabled": true])]
        let steps = FakeJiraSteps()
        steps.spaces = [ConnectChoice(id: "DOC", name: "Docs", selected: true),
                        ConnectChoice(id: "ENG", name: "Engineering", selected: false)]
        let driver = JiraConnectDriver(model: model, steps: steps, policy: Self.open, companySlug: Self.noCompany)
        let listed = try await driver.choose(kind: "confluence_spaces", select: nil).get()
        XCTAssertEqual(listed.map(\.id), ["DOC", "ENG"])
        _ = try await driver.choose(kind: "confluence_spaces", select: ["DOC", "ENG"]).get()
        XCTAssertEqual(steps.selected, ["ENG"])
        XCTAssertEqual(steps.spacesAccount, 3)
    }

    // MARK: - Linear

    func testChooseLinearTeams() async throws {
        let model = FakeLinearModel()
        model.accounts = [LinearAccount(id: 7, label: "Acme")]
        model.teams = [7: [LinearTeam(key: "ENG", name: "Engineering", selected: false),
                           LinearTeam(key: "OPS", name: "Operations", selected: true)]]
        let driver = LinearConnectDriver(model: model, policy: Self.open)
        let listed = try await driver.choose(kind: "linear_teams", select: nil).get()
        XCTAssertEqual(listed, [ConnectChoice(id: "ENG", name: "Engineering", selected: false),
                                ConnectChoice(id: "OPS", name: "Operations", selected: true)])
        let picked = try await driver.choose(kind: "linear_teams", select: ["ENG"]).get()
        XCTAssertEqual(picked.map(\.selected), [true, false])
        XCTAssertEqual(model.setTeams.map { "\($0.key)=\($0.selected)" }, ["ENG=true", "OPS=false"])
        if case .success = await driver.choose(kind: "linear_teams", select: ["NOPE"]) { XCTFail("unknown team") }
        let none = await LinearConnectDriver(model: FakeLinearModel(), policy: Self.open).choose(kind: "linear_teams", select: nil)
        guard case .failure(.failed) = none else { return XCTFail("\(none)") }
    }

    // MARK: - Quick Connections

    func testQuickConnectionEnableNeedsConfirm() async throws {
        let model = FakeQuickModel()
        model.connections = [Self.connection(1, "docs", url: "https://docs.example.com/mcp")]
        let driver = QuickConnectionConnectDriver(model: model, policy: Self.open)
        XCTAssertNil(driver.confirmNeeded(tool: "connect_start", options: [:]))
        // A start that never got the card enables nothing.
        let unconfirmed = await driver.start(options: ["enable": "docs"])
        guard case .failure = unconfirmed else { return XCTFail("\(unconfirmed)") }
        XCTAssertTrue(model.enabled.isEmpty)

        XCTAssertEqual(driver.confirmNeeded(tool: "connect_start", options: ["enable": "docs"]), .quickConnection(name: "docs"))
        let flowID = try await driver.start(options: ["enable": "docs"]).get()
        await driver.flows.finished(flowID)
        XCTAssertEqual(model.enabled, ["docs"])
        let outcome = await driver.wait(flowID: flowID)
        XCTAssertEqual(outcome, .connected(account: "docs (2 read-only tools)"))

        // The organization's AllowedQuickConnections refuses it: no card, no enable.
        let blocked = ManagedPolicy.normalize(["AllowedQuickConnections": ["https://other.example.com/"]])
        let blockedPolicy: @MainActor () -> ManagedPolicy = { blocked }
        let strict = QuickConnectionConnectDriver(model: model, policy: blockedPolicy)
        XCTAssertNil(strict.confirmNeeded(tool: "connect_start", options: ["enable": "docs"]))
        let refused = await strict.start(options: ["enable": "docs"])
        XCTAssertEqual(refused.failureValue, .policy)
        XCTAssertEqual(model.enabled, ["docs"])
    }

    func testQuickConnectionAddWithoutKeyStartsAFlow() async throws {
        let model = FakeQuickModel()
        let driver = QuickConnectionConnectDriver(model: model, policy: Self.open)
        let server = ["name": "files", "kind": "stdio", "command": "/usr/local/bin/files-mcp", "args": "--root '/tmp/a b'"]
        _ = try await driver.setFields(server).get()
        let flowID = try await driver.start(options: [:]).get()
        await driver.flows.finished(flowID)
        XCTAssertEqual(model.added?.args, ["--root", "/tmp/a b"])
        XCTAssertNil(model.added?.secretJSON)
        let outcome = await driver.wait(flowID: flowID)
        XCTAssertEqual(outcome, .connected(account: "files"))
        // A server with a key goes through request_secret.
        _ = await driver.setFields(["variable": "API_KEY"])
        if case .success = await driver.start(options: [:]) { XCTFail("a keyed server starts through request_secret") }
    }

    // MARK: - Policy and busy

    func testPolicyBlockedEachService() async {
        let slackOnly = ManagedPolicy.normalize(["AllowedSources": ["slack"]])
        let slackPolicy: @MainActor () -> ManagedPolicy = { slackOnly }
        let noQuick = ManagedPolicy.normalize(["AllowedQuickConnections": [String]()])
        let noQuickPolicy: @MainActor () -> ManagedPolicy = { noQuick }
        let drivers: [any ConnectServiceDriving] = [
            GoogleConnectDriver(model: FakeGoogleModel(), policy: slackPolicy),
            EmailConnectDriver(model: FakeEmailModel(), policy: slackPolicy),
            CalendarConnectDriver(model: FakeCalendarModel(), policy: slackPolicy),
            JiraConnectDriver(model: FakeJiraModel(), steps: FakeJiraSteps(), policy: slackPolicy, companySlug: Self.noCompany),
            LinearConnectDriver(model: FakeLinearModel(), policy: slackPolicy)
        ]
        for driver in drivers {
            XCTAssertFalse(PolicySourceMap.allowed(driver.service, policy: slackOnly), driver.service)
            XCTAssertFalse(driver.policyAllows(), driver.service)
            let locked = await driver.status().policyLocked
            XCTAssertTrue(locked, driver.service)
        }
        let quick = QuickConnectionConnectDriver(model: FakeQuickModel(), policy: noQuickPolicy)
        XCTAssertFalse(quick.policyAllows())
        XCTAssertTrue(QuickConnectionConnectDriver(model: FakeQuickModel(), policy: slackPolicy).policyAllows())

        // A secret verb re-checks the policy itself.
        let email = FakeEmailModel()
        let emailDriver = EmailConnectDriver(model: email, policy: slackPolicy)
        _ = await emailDriver.setFields(["host": "imap.example.com", "username": "me"])
        let refused = await emailDriver.submitSecret(kind: "imap_password", value: "pw")
        XCTAssertEqual(refused.failureValue, .policy)
        XCTAssertTrue(email.calls.isEmpty)
    }

    func testBusyWhenViewModelFlowRunning() async {
        let google = FakeGoogleModel()
        google.isConnecting = true
        let googleStart = await GoogleConnectDriver(model: google, policy: Self.open).start(options: ["scopes": "calendar"])
        XCTAssertEqual(googleStart.failureValue, .busy)

        let email = FakeEmailModel()
        email.isRunning = true
        let emailDriver = EmailConnectDriver(model: email, policy: Self.open)
        _ = await emailDriver.setFields(["host": "imap.example.com", "username": "me"])
        let outlook = await emailDriver.start(options: ["outlook": "true"])
        XCTAssertEqual(outlook.failureValue, .busy)
        let imap = await emailDriver.submitSecret(kind: "imap_password", value: "pw")
        XCTAssertEqual(imap.failureValue, .busy)

        let calendar = FakeCalendarModel()
        calendar.isRunning = true
        let ics = await CalendarConnectDriver(model: calendar, policy: Self.open).submitSecret(kind: "ics_url", value: "u")
        XCTAssertEqual(ics.failureValue, .busy)

        let jira = FakeJiraModel()
        jira.isConnecting = true
        let jiraStart = await JiraConnectDriver(model: jira, steps: FakeJiraSteps(), policy: Self.open, companySlug: Self.noCompany)
            .start(options: [:])
        XCTAssertEqual(jiraStart.failureValue, .busy)

        let linear = FakeLinearModel()
        linear.isBusy = true
        let linearDriver = LinearConnectDriver(model: linear, policy: Self.open)
        let linearStart = await linearDriver.start(options: ["oauth": "true"])
        XCTAssertEqual(linearStart.failureValue, .busy)
        let key = await linearDriver.submitSecret(kind: "linear_api_key", value: "k")
        XCTAssertEqual(key.failureValue, .busy)

        let quick = FakeQuickModel()
        quick.isBusy = true
        let quickDriver = QuickConnectionConnectDriver(model: quick, policy: Self.open)
        _ = await quickDriver.setFields(["name": "docs", "kind": "http", "url": "https://mcp.example.com"])
        let quickStart = await quickDriver.start(options: [:])
        XCTAssertEqual(quickStart.failureValue, .busy)

        XCTAssertTrue(email.calls.isEmpty)
        XCTAssertTrue(calendar.calls.isEmpty)
        XCTAssertTrue(linear.calls.isEmpty)
        XCTAssertTrue(quick.calls.isEmpty)
    }

    // MARK: - Review fixes

    /// The view models cut stderr at 200 characters, so only a piece of a
    /// long secret may be left in it: that piece never reaches the agent.
    func testLongSecretCutInErrorIsHidden() async {
        let secret = "https://cal.example.com/feeds/" + String(repeating: "a1b2c3d4", count: 30) + ".ics"
        let stderr = String(("caldav add-ics: cannot read " + secret + ": 404").prefix(200))
        XCTAssertFalse(stderr.contains(secret), "the fixture keeps only a piece")
        let model = FakeCalendarModel()
        model.failWith = { stderr }
        let result = await CalendarConnectDriver(model: model, policy: Self.open).submitSecret(kind: "ics_url", value: secret)
        guard case let .failure(.failed(message)) = result else { return XCTFail("\(result)") }
        XCTAssertFalse(ConnectSecret.holdsPiece(of: secret, in: message))
        XCTAssertFalse(message.contains("a1b2c3d4"))
        // An error without any piece of the secret still says why.
        let plain = ConnectSecret.failure("imap add: connection test failed: timeout", secret: "hunter22pw", fallback: "x")
        XCTAssertEqual(plain, .failed("imap add: connection test failed: timeout"))
    }

    func testQuickConnectionApprovalIsForTheRowTheCardShowed() async throws {
        let model = FakeQuickModel()
        model.connections = [Self.connection(1, "docs", url: "https://docs.example.com/mcp")]
        let driver = QuickConnectionConnectDriver(model: model, policy: Self.open)
        XCTAssertNil(driver.confirmNeeded(tool: "connect_start", options: ["enable": "nope"]), "no card for an unknown name")
        XCTAssertNotNil(driver.confirmNeeded(tool: "connect_start", options: ["enable": "docs"]))
        // Removed and added again under the same name while the card was open.
        model.connections = [Self.connection(2, "docs", url: "https://evil.example.com/mcp")]
        let refused = await driver.start(options: ["enable": "docs"])
        guard case .failure(.failed) = refused else { return XCTFail("\(refused)") }
        XCTAssertTrue(model.enabled.isEmpty)
        // A fresh card for the new row enables it.
        XCTAssertNotNil(driver.confirmNeeded(tool: "connect_start", options: ["enable": "docs"]))
        let flowID = try await driver.start(options: ["enable": "docs"]).get()
        await driver.flows.finished(flowID)
        XCTAssertEqual(model.enabled, ["docs"])
    }

    func testQuickConnectionCancelledSignInIsNotConnected() async throws {
        let model = FakeQuickModel()
        model.signInCancels = true
        let driver = QuickConnectionConnectDriver(model: model, policy: Self.open)
        _ = try await driver.setFields(["name": "docs", "kind": "http", "url": "https://mcp.example.com", "oauth": "true"]).get()
        let flowID = try await driver.start(options: [:]).get()
        await driver.flows.finished(flowID)
        let outcome = await driver.wait(flowID: flowID)
        XCTAssertEqual(outcome, .failed(reason: "the sign-in was cancelled: docs is added but not signed in"))
    }

    func testJiraSiteQuestionListsTheSites() async throws {
        let model = FakeJiraModel()
        let driver = JiraConnectDriver(model: model, steps: FakeJiraSteps(), policy: Self.open, companySlug: Self.noCompany)
        let flowID = try await driver.start(options: [:]).get()
        await model.until { model.added != nil }
        model.siteChoices = [JiraSiteChoice(url: "https://alpha.atlassian.net", name: "alpha"),
                             JiraSiteChoice(url: "https://beta.atlassian.net", name: "beta")]
        let state = await driver.status().flow?.state
        XCTAssertEqual(state, "choose_site: alpha (https://alpha.atlassian.net); beta (https://beta.atlassian.net)")
        model.gate.open()
        await driver.flows.finished(flowID)
    }

    func testJiraPendingSiteDiesWithItsFlow() async throws {
        let model = FakeJiraModel()
        let driver = JiraConnectDriver(model: model, steps: FakeJiraSteps(), policy: Self.open, companySlug: Self.noCompany)
        let first = try await driver.start(options: [:]).get()
        await model.until { model.added != nil }
        _ = try await driver.setFields(["site": "alpha.atlassian.net"]).get()  // before any question
        model.gate.open()
        await driver.flows.finished(first)
        model.gate = Gate()
        let second = try await driver.start(options: [:]).get()
        await model.until { model.added?.site == nil && model.isConnecting }
        XCTAssertNil(model.added?.site, "the old flow's answer is no --site for the next one")
        await driver.cancel(flowID: second)
        await driver.flows.finished(second)

        // A site named with no flow running is the next start's --site.
        _ = try await driver.setFields(["site": "beta.atlassian.net"]).get()
        model.gate = Gate()
        model.connects = true
        let third = try await driver.start(options: [:]).get()
        await model.until { model.added?.site == "beta.atlassian.net" }
        model.gate.open()
        await driver.flows.finished(third)
    }

    func testJiraRestartWaitsForTheBoardPick() async throws {
        let model = FakeJiraModel()
        let steps = FakeJiraSteps()
        let daemon = FakeDaemonRestarter()
        let driver = JiraConnectDriver(
            model: model, steps: steps, policy: Self.open, companySlug: Self.noCompany, daemon: daemon)
        let flowID = try await driver.start(options: [:]).get()
        model.gate.open()
        await driver.flows.finished(flowID)
        XCTAssertNil(driver.restartTask, "held while the boards are not picked")
        XCTAssertEqual(model.policies, [.deferred], "the view model restarts nothing for the driver")
        steps.boards = [Self.board(1, 10, selected: false)]
        _ = try await driver.choose(kind: "jira_boards", select: ["1:10"]).get()
        await driver.restartTask?.value
        XCTAssertEqual(daemon.restartCount, 1)
        driver.runEnded()
        await driver.restartTask?.value
        XCTAssertEqual(daemon.restartCount, 1, "released once")

        // No pick: the run's end releases it.
        model.gate = Gate()
        let again = try await driver.start(options: [:]).get()
        model.gate.open()
        await driver.flows.finished(again)
        driver.runEnded()
        await driver.restartTask?.value
        XCTAssertEqual(daemon.restartCount, 2)

        // A connect the customer cancelled restarts nothing.
        model.gate = Gate()
        let cancelled = try await driver.start(options: [:]).get()
        await driver.cancel(flowID: cancelled)
        await driver.flows.finished(cancelled)
        driver.runEnded()
        await driver.restartTask?.value
        XCTAssertEqual(daemon.restartCount, 2)
    }

    /// The run ends while the sign-in still runs: when it succeeds later,
    /// nothing would release a held restart, so it restarts at once.
    func testJiraRunEndedDuringSignInRestartsOnSuccess() async throws {
        let model = FakeJiraModel()
        let daemon = FakeDaemonRestarter()
        let driver = JiraConnectDriver(
            model: model, steps: FakeJiraSteps(), policy: Self.open, companySlug: Self.noCompany, daemon: daemon)
        let flowID = try await driver.start(options: [:]).get()
        await model.until { model.isConnecting }
        driver.runEnded()
        XCTAssertNil(driver.restartTask)
        model.gate.open()
        await driver.flows.finished(flowID)
        await driver.restartTask?.value
        XCTAssertEqual(daemon.restartCount, 1)
    }

    /// The add sheet holds its own restart for site B while the driver's
    /// site A waits: the driver's release is its own daemon restart and
    /// leaves the sheet's hold alone (#572).
    func testJiraDriverReleaseLeavesTheSheetsHeldRestart() async throws {
        let model = FakeJiraModel()
        let steps = FakeJiraSteps()
        let daemon = FakeDaemonRestarter()
        let driver = JiraConnectDriver(
            model: model, steps: steps, policy: Self.open, companySlug: Self.noCompany, daemon: daemon)
        let flowID = try await driver.start(options: [:]).get()
        model.gate.open()
        await driver.flows.finished(flowID)
        model.sheetHeldRestart = true  // the sheet adds site B and holds its restart
        steps.boards = [Self.board(1, 10, selected: false)]
        _ = try await driver.choose(kind: "jira_boards", select: ["1:10"]).get()
        await driver.restartTask?.value
        XCTAssertEqual(daemon.restartCount, 1)
        XCTAssertTrue(model.sheetHeldRestart, "B's held restart is intact")
    }

    /// The add saved the site, but the list could not be re-read: the
    /// restart still follows the save.
    func testJiraSavedSiteRestartsEvenWhenTheReloadFails() async throws {
        let model = FakeJiraModel()
        model.reloadFails = true
        let daemon = FakeDaemonRestarter()
        let driver = JiraConnectDriver(
            model: model, steps: FakeJiraSteps(), policy: Self.open, companySlug: Self.noCompany, daemon: daemon)
        let flowID = try await driver.start(options: [:]).get()
        model.gate.open()
        await driver.flows.finished(flowID)
        let outcome = await driver.wait(flowID: flowID)
        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertNil(driver.restartTask, "held for the board pick")
        driver.runEnded()
        await driver.restartTask?.value
        XCTAssertEqual(daemon.restartCount, 1)
    }

    /// A Cancel that lands after the CLI saved the site: no board step
    /// follows, so the restart runs at once.
    func testJiraLateCancelAfterSaveRestarts() async throws {
        let model = FakeJiraModel()
        model.cancelLate = true
        let daemon = FakeDaemonRestarter()
        let driver = JiraConnectDriver(
            model: model, steps: FakeJiraSteps(), policy: Self.open, companySlug: Self.noCompany, daemon: daemon)
        let flowID = try await driver.start(options: [:]).get()
        model.gate.open()
        await driver.flows.finished(flowID)
        await driver.restartTask?.value
        XCTAssertEqual(daemon.restartCount, 1)
    }

    func testQuickConnectionSignInIsReadBackBeforeTheAnswer() async throws {
        let model = FakeQuickModel()
        let driver = QuickConnectionConnectDriver(model: model, policy: Self.open)
        _ = try await driver.setFields(["name": "docs", "kind": "http", "url": "https://mcp.example.com", "oauth": "true"]).get()
        let flowID = try await driver.start(options: [:]).get()
        await driver.flows.finished(flowID)
        XCTAssertEqual(model.events.suffix(2), ["signIn", "refresh"])
        let outcome = await driver.wait(flowID: flowID)
        XCTAssertEqual(outcome, .connected(account: "docs"))
    }

    func testQuickConnectionCancelDuringAddOpensNoSignIn() async throws {
        let model = FakeQuickModel()
        let driver = QuickConnectionConnectDriver(model: model, policy: Self.open)
        _ = try await driver.setFields(["name": "docs", "kind": "http", "url": "https://mcp.example.com", "oauth": "true"]).get()
        let flowID = try await driver.start(options: [:]).get()
        model.onAdd = { await driver.cancel(flowID: flowID) }
        await driver.flows.finished(flowID)
        XCTAssertTrue(model.signIns.isEmpty, "no sign-in opens after a Cancel")
        XCTAssertEqual(model.signInCancelCalls, 0, "the add's busy flag is left alone")
        let outcome = await driver.wait(flowID: flowID)
        XCTAssertEqual(outcome, .failed(reason: "the sign-in was cancelled before it opened: docs is added but not signed in"))
    }

    func testQuickConnectionCancelAfterSignInFinishedKeepsTheRealOutcome() async throws {
        let model = FakeQuickModel()
        let driver = QuickConnectionConnectDriver(model: model, policy: Self.open)
        _ = try await driver.setFields(["name": "docs", "kind": "http", "url": "https://mcp.example.com", "oauth": "true"]).get()
        let flowID = try await driver.start(options: [:]).get()
        model.onSignInDone = { await driver.cancel(flowID: flowID) }  // the sign-in exited 0 first
        await driver.flows.finished(flowID)
        XCTAssertEqual(model.signIns, ["docs"])
        let outcome = await driver.wait(flowID: flowID)
        XCTAssertEqual(outcome, .connected(account: "docs"))
    }

    // MARK: - Fixtures

    static let open: @MainActor () -> ManagedPolicy = { .none }
    static let noCompany: @MainActor () -> String? = { nil }
    static let acme: @MainActor () -> String? = { "acme" }

    static func board(_ accountID: Int64, _ id: Int, selected: Bool) -> JiraBoard {
        JiraBoard(
            accountID: accountID, id: id, name: "Board \(id)", projectKey: "PROJ", boardType: "scrum",
            isSelected: selected, issueCount: 0, syncedAt: "", rawColumnsJSON: "", rawConfigJSON: "",
            llmProfileJSON: "", workflowSummary: "", userOverridesJSON: "", configHash: "", profileGeneratedAt: "")
    }

    static func connection(_ id: Int, _ name: String, url: String, enabled: Bool = false) -> ExternalConnection {
        ExternalConnection(row: ["id": id, "name": name, "kind": "http", "url": url, "enabled": enabled, "status": "ok"])
    }
}

private extension Result {
    var failureValue: Failure? {
        if case let .failure(error) = self { return error }
        return nil
    }
}

// MARK: - Fakes

/// Holds a fake flow until the test opens it.
@MainActor
private final class Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

@MainActor
private final class FakeGoogleModel: GoogleConnectModel {
    var isConnecting = false
    var error: String?
    var connectRows: [ConnectAccountRow] = []
    var addTask: Task<Void, Never>?
    var added: (calendar: Bool, gmail: Bool, clientID: String)?
    var newRow: ConnectAccountRow?
    var cancels = 0
    let gate = Gate()

    func addAccount(
        calendar: Bool, gmail: Bool, clientID: String, clientSecret: String, daemonPolicy: DaemonRestartPolicy
    ) -> Bool {
        added = (calendar, gmail, clientID)
        isConnecting = true
        addTask = Task {
            await gate.wait()
            isConnecting = false
            if let newRow { connectRows.append(newRow) }
        }
        return true
    }

    func cancelConnect() {
        cancels += 1
        newRow = nil
        gate.open()
    }

    func refreshAsync() async {}
}

@MainActor
private final class FakeEmailModel: EmailConnectModel {
    var isRunning = false
    var error: String?
    var outlookError: String?
    var connectRows: [ConnectAccountRow] = []
    var outlookTask: Task<Void, Never>?
    var calls: [String] = []
    var password: String?
    struct Imap {
        let host: String, port: Int, username: String, folder: String, security: String
    }
    var imap: Imap?
    let gate = Gate()

    func addImapAccount(
        host: String, port: Int, username: String, password: String, folder: String, security: String
    ) async -> Bool {
        calls.append("imap")
        self.password = password
        imap = Imap(host: host, port: port, username: username, folder: folder, security: security)
        connectRows.append(ConnectAccountRow(id: 1, ConnectionAccountState(name: username, isOK: true, status: "ok", error: "")))
        return true
    }

    func connectOutlook() {
        calls.append("outlook")
        isRunning = true
        outlookTask = Task {
            await gate.wait()
            isRunning = false
            error = outlookError
        }
    }

    func cancelConnect() {
        gate.open()
    }

    func refreshAsync() async {}
}

@MainActor
private final class FakeCalendarModel: CalendarConnectModel {
    var isRunning = false
    var error: String?
    var connectRows: [ConnectAccountRow] = []
    var calls: [String] = []
    var received: String?
    var failWith: (() -> String)?

    func addCalDAV(url: String, username: String, password: String) async -> Bool {
        calls.append("caldav")
        received = password
        return finish(name: username)
    }

    func addICS(feedURL: String) async -> Bool {
        calls.append("ics")
        received = feedURL
        return finish(name: "ICS feed")
    }

    private func finish(name: String) -> Bool {
        if let failWith {
            error = failWith()
            return false
        }
        connectRows.append(ConnectAccountRow(id: connectRows.count + 1,
                                             ConnectionAccountState(name: name, isOK: true, status: "ok", error: "")))
        return true
    }

    func refreshAsync() async {}
}

@MainActor
private final class FakeJiraModel: JiraConnectModel {
    var isConnecting = false
    var error: String?
    var accounts: [JiraAccount] = []
    var siteChoices: [JiraSiteChoice]?
    var added: (withConfluence: Bool, company: String?, site: String?)?
    var chosenSite: JiraSiteChoice?
    var gate = Gate()

    var connects = true
    var policies: [DaemonRestartPolicy] = []
    /// The add sheet's held restart for its own site (not the driver's to touch).
    var sheetHeldRestart = false
    /// The add saves the site but the reload fails (the list keeps the old rows).
    var reloadFails = false
    /// The Cancel lands after the CLI saved the site.
    var cancelLate = false

    func addAccount(
        withConfluence: Bool, company: String?, site: String?, daemonPolicy: DaemonRestartPolicy
    ) async -> JiraAccountsViewModel.AuthFlowEnd {
        added = (withConfluence, company, site)
        policies.append(daemonPolicy)
        isConnecting = true
        await gate.wait()
        isConnecting = false
        guard connects else { return .cancelled }
        if reloadFails { return .finished }
        accounts.append(JiraAccount(row: ["id": accounts.count + 1, "site_name": "acme", "enabled": true]))
        return cancelLate ? .cancelledAfterConnecting : .finished
    }

    func chooseSite(_ site: JiraSiteChoice) {
        chosenSite = site
    }

    func cancelConnect() {
        connects = false
        gate.open()
    }

    func refreshAsync() async {
        if reloadFails { error = "Failed to load accounts: disk I/O error" }
    }

    /// Yields until `condition` holds (the driver's flow task runs on the main actor).
    func until(_ condition: () -> Bool) async {
        while !condition() { await Task.yield() }
    }
}

@MainActor
private final class FakeJiraSteps: JiraConnectSteps {
    var line = ""
    var lineBefore: Set<Int>?
    var boards: [JiraBoard] = []
    var fetchedSites: [[Int]] = []
    var saved: [[String]] = []
    var spaces: [ConnectChoice] = []
    var selected: [String] = []
    var spacesAccount: Int?

    func confluenceLine(accountIDsBefore: Set<Int>?) async -> String {
        lineBefore = accountIDsBefore
        return line
    }

    func boards(of sites: [JiraAccount]) async -> (boards: [JiraBoard], failure: String?) {
        fetchedSites.append(sites.map(\.id))
        return (boards, nil)
    }

    func saveBoards(_ calls: [[String]]) async -> String? {
        saved += calls
        return nil
    }

    func spaces(accountID: Int) async -> Result<[ConnectChoice], ConnectDriverError> {
        spacesAccount = accountID
        return .success(spaces)
    }

    func selectSpaces(_ keys: [String], accountID: Int) async -> String? {
        selected += keys
        return nil
    }
}

@MainActor
private final class FakeLinearModel: LinearConnectModel {
    var isBusy = false
    var error: String?
    var accounts: [LinearAccount] = []
    var teams: [Int64: [LinearTeam]] = [:]
    var teamErrors: [Int64: String] = [:]
    var calls: [String] = []
    var key: String?
    var setTeams: [(key: String, selected: Bool)] = []

    func addWithOAuth(daemonPolicy: DaemonRestartPolicy) async {
        calls.append("oauth")
    }

    func addWithAPIKey(_ key: String, daemonPolicy: DaemonRestartPolicy) async -> Bool {
        calls.append("apiKey")
        self.key = key
        accounts.append(LinearAccount(id: 11, label: "Acme"))
        return true
    }

    func loadTeams(for account: LinearAccount) async {}

    func setTeam(_ team: LinearTeam, selected: Bool, for account: LinearAccount) async {
        setTeams.append((team.key, selected))
        teams[account.id] = teams[account.id]?.map {
            $0.key == team.key ? LinearTeam(key: $0.key, name: $0.name, selected: selected) : $0
        }
    }

    func cancelConnect() {}

    func refreshAsync() async {}
}

@MainActor
private final class FakeQuickModel: QuickConnectionConnectModel {
    var isBusy = false
    var error: String?
    var connections: [ExternalConnection] = []
    var toolLists: [Int: ExternalConnectionTools] = [:]
    var calls: [String] = []
    var secretJSON: String?
    var added: (name: String, args: [String], secretJSON: String?)?
    var enabled: [String] = []
    var lastSignInCancelled = false
    var signInCancels = false
    var signIns: [String] = []
    var signInCancelCalls = 0
    var onAdd: (() async -> Void)?
    var onSignInDone: (() async -> Void)?
    var events: [String] = []

    func addConnection(
        name: String, kind: String, command: String, args: [String], url: String, secretJSON: String?, useOAuth: Bool
    ) async {
        calls.append("add")
        self.secretJSON = secretJSON
        added = (name, args, secretJSON)
        XCTAssertFalse(useOAuth, "the driver runs the sign-in itself")
        connections.append(PersonalConnectDriverTests.connection(connections.count + 1, name, url: url))
        await onAdd?()
    }

    func signIn(_ connection: ExternalConnection) async {
        signIns.append(connection.name)
        events.append("signIn")
        lastSignInCancelled = signInCancels
        await onSignInDone?()
    }

    func setEnabled(_ connection: ExternalConnection, enabled: Bool) async {
        if enabled { self.enabled.append(connection.name) }
    }

    func loadTools(_ connection: ExternalConnection) async {
        toolLists[connection.id] = ExternalConnectionTools(
            id: Int64(connection.id), name: connection.name, listed: true, listedAt: nil, explicit: false, stale: false,
            tools: [.init(name: "a", allowed: true, readOnly: true, write: false),
                    .init(name: "b", allowed: true, readOnly: true, write: false),
                    .init(name: "c", allowed: false, readOnly: false, write: true)])
    }

    func cancelSignIn() {
        signInCancelCalls += 1
    }

    func refreshAsync() async {
        events.append("refresh")
    }
}

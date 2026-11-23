import Testing
@testable import WatchtowerCore
import WatchtowerTestSupport

@Suite("ConnectAssistantPresentation")
@MainActor
struct ConnectAssistantPresentationTests {
    private typealias Pres = ConnectAssistantPresentation

    /// The catalog's rows (`ai_models_capabilities.json`): Claude drives the
    /// browser, Codex guides in words.
    private let claude = ConnectHarness.fixture("claude")
    private let codex = ConnectHarness.fixture("codex")
    /// A browser harness named Codex: the mode line once a second harness
    /// drives the browser.
    private let codexBrowser = ConnectHarness(id: "codex", name: "Codex", capability: .browser)

    private func slack(
        _ state: ConnectAssistantState,
        harness: ConnectHarness? = nil,
        mode: ConnectAssistantMode = .browser,
        browser: Bool = true
    ) -> Pres {
        Pres(service: "Slack", harness: harness ?? claude, mode: mode, browserAvailable: browser, state: state)
    }

    @Test("header and mode line name the harness, or say words mode")
    func header() {
        #expect(slack(.empty).title == "Connect Slack")
        #expect(slack(.empty).harness == "Claude")
        #expect(slack(.empty).modeLine == "Using Claude in Chrome")
        #expect(slack(.empty, harness: codexBrowser).modeLine == "Using Codex in Chrome")
        #expect(slack(.empty, mode: .words).modeLine == "I'll tell you each step")
        #expect(slack(.empty, browser: false).modeLine == "I'll tell you each step")
        #expect(slack(.empty).composerPlaceholder == "Ask a question…")
    }

    @Test("empty invites to start; browser mode also offers words; by hand is always there")
    func empty() {
        let browser = slack(.empty)
        #expect(browser.intro == "I'll connect Slack with you. Start?")
        #expect(browser.actions == [.start, .guideInWords, .setUpByHand])
        #expect(browser.actions.map(\.title) == ["Start", "Guide me in words", "Set up by hand"])
        #expect(browser.status == nil && browser.card == nil)
        #expect(slack(.empty, mode: .words).actions == [.start, .setUpByHand])
    }

    @Test("narrow scope: no browser, words only, and the panel says why")
    func narrow() {
        let claude = slack(.empty, browser: false)
        #expect(claude.intro == "I'll connect Slack with you. Claude in Chrome isn't connected, so I can't use "
            + "your browser. I'll tell you each step and check it. Start?")
        #expect(claude.actions == [.start, .setUpByHand])
        let words = slack(.empty, harness: codex, browser: false)
        #expect(words.intro == "I'll connect Slack with you. Codex can't use your browser yet. "
            + "I'll tell you each step and check it. Start?")
    }

    @Test("no browser before the run: the guide, Check again, Continue without the browser, by hand")
    func browserMissing() {
        let missing = Pres(service: "Slack", harness: claude, mode: .words, browserAvailable: false,
                           state: .browserMissing, browserCheck: .notChecked)
        #expect(missing.intro == "I'll connect Slack with you. Claude in Chrome isn't connected, so I can't use "
            + "your browser. Connect it and press Check again, or continue and I'll tell you each step.")
        #expect(missing.modeLine == "I'll tell you each step")
        #expect(missing.actions.map(\.title) == ["Check again", "Continue without the browser", "Set up by hand"])
        #expect(missing.status == nil && missing.card == nil)
        let guide = try? #require(missing.browserGuide)
        #expect(guide?.title == "Connect Claude in Chrome")
        #expect(guide?.steps == [
            "Install the Claude extension for Chrome.",
            "Open it in Chrome and sign in with the same claude.ai account Claude uses on this Mac.",
            "If you just installed it, restart Chrome."
        ])
        #expect(guide?.linkTitle == "claude.ai/chrome")
        #expect(guide?.link.absoluteString == "https://claude.ai/chrome")
        #expect(guide?.lead == nil && guide?.note == nil)

        let checking = Pres(service: "Slack", harness: claude, mode: .words, browserAvailable: false,
                            state: .browserMissing, browserCheck: .checking)
        #expect(checking.browserGuide?.note == "Checking for Claude in Chrome…")
        #expect(checking.actions == [.cancel])
        let still = Pres(service: "Slack", harness: claude, mode: .words, browserAvailable: false,
                         state: .browserMissing, browserCheck: .stillMissing)
        #expect(still.browserGuide?.note == "Still not connected.")
        #expect(still.actions == [.checkBrowser, .continueWithoutBrowser, .setUpByHand])
    }

    @Test("the browser lost mid-run: the guide and Check again beside the run, never over a card")
    func browserLost() {
        func lost(_ state: ConnectAssistantState, _ check: ConnectBrowserCheck? = .notChecked) -> Pres {
            Pres(service: "Slack", harness: claude, mode: .words, browserAvailable: false, state: state,
                 browserCheck: check)
        }
        #expect(lost(.thinking).browserGuide?.lead
            == "Claude in Chrome isn't connected any more, so I'm telling you each step.")
        #expect(lost(.thinking).actions == [.cancel, .checkBrowser])
        #expect(lost(.listening).actions == [.cancel, .checkBrowser])
        #expect(lost(.waiting(step: "press Allow")).actions == [.cancel, .checkBrowser])
        #expect(lost(.thinking, .checking).actions == [.cancel])
        #expect(lost(.thinking, .stillMissing).browserGuide?.note == "Still not connected.")
        #expect(lost(.secret(label: "Token")).browserGuide == nil)
        #expect(lost(.confirm(.slackPKCE)).browserGuide == nil)
        #expect(lost(.failed(.quota)).browserGuide == nil)
        #expect(lost(.done(accounts: 1, noun: .workspace)).browserGuide == nil)
        #expect(lost(.thinking, nil).browserGuide == nil, "declined, or never lost: no guide")
        #expect(slack(.empty).browserGuide == nil)
    }

    @Test("loading: working, or waiting for the customer in the browser, with Cancel")
    func loading() {
        #expect(slack(.thinking).status == .init(kind: .progress, text: "Working on it…"))
        let waiting = slack(.waiting(step: "press Allow in Slack"))
        #expect(waiting.status == .init(kind: .progress, text: "Waiting for you to press Allow in Slack"))
        #expect(waiting.actions.map(\.title) == ["Cancel"])
    }

    @Test("listening: the agent waits on the composer, no status line, Cancel stays")
    func listening() {
        let listening = slack(.listening)
        #expect(listening.status == nil && listening.card == nil && listening.intro == nil)
        #expect(listening.actions.map(\.title) == ["Cancel"])
    }

    @Test("every failure offers Retry and Set up by hand")
    func failed() {
        let quota = slack(.failed(.quota))
        #expect(quota.status == .init(kind: .problem,
                                      text: "Claude has reached its usage limit. Retry later or switch the assistant above."))
        #expect(quota.actions.map(\.title) == ["Retry", "Set up by hand"])
        #expect(slack(.failed(.agent(reason: nil))).status?.text == "Claude stopped before Slack was connected.")
        #expect(slack(.failed(.agent(reason: "the page didn't load."))).status?.text
            == "Claude stopped: the page didn't load.")
        #expect(slack(.failed(.harnessMissing), harness: codex).status?.text
            == "Codex isn't installed on this Mac. Switch the assistant above or set up by hand.")
    }

    @Test("a run that waited too long says so and offers Retry")
    func testTimedOutCopy() {
        let timedOut = slack(.failed(.timedOut))
        #expect(timedOut.status == .init(kind: .problem,
                                         text: "I stopped waiting after 15 minutes. Press Retry when you're ready."))
        #expect(timedOut.actions == [.retry, .setUpByHand])
    }

    @Test("busy points at the other window")
    func busy() {
        let busy = slack(.busy)
        #expect(busy.status?.text == "Slack is already connecting in another window")
        #expect(busy.actions.map(\.title) == ["Open it"])
    }

    @Test("the secret card says the harness never sees the value")
    func secret() {
        guard case .secret(let card) = slack(.secret(label: "Slack configuration token")).card
        else { Issue.record("no secret card"); return }
        #expect(card.label == "Slack configuration token")
        #expect(card.placeholder == "Paste it here")
        #expect(card.footnote == "Goes straight to Watchtower — Claude doesn't see it")
        #expect(card.send == "Send")
        #expect(Pres.secretFootnote(codex) == "Goes straight to Watchtower — Codex doesn't see it")
    }

    @Test("the secret card asks to close the vendor's page first; a password needs no such line")
    func testSecretCardAsksToCloseFirst() {
        func card(_ kind: String?) -> Pres.SecretCard? {
            guard case .secret(let card) = Pres(service: "Acme", harness: claude, mode: .browser,
                                                state: .secret(label: "Client secret"), secretKind: kind).card
            else { return nil }
            return card
        }
        #expect(card("google_client_secret")?.closeFirst == "Close Google's dialog, then Send.")
        #expect(card("atlassian_client_secret")?.closeFirst == "Leave Atlassian's Settings page, then Send.")
        #expect(card("slack_config_token")?.closeFirst == "Leave Slack's token page, then Send.")
        #expect(card("imap_password")?.closeFirst == nil)
        #expect(card(nil)?.closeFirst == nil)
        #expect(card(nil)?.dismiss == "Don't send")
    }

    @Test("the help text names what v1 cannot enforce")
    func testHelpTextNamesV1Limit() {
        let browser = slack(.empty).helpText
        #expect(browser == "Claude works in your own Chrome. It opens only the pages this setup needs, but a link, "
            + "a form or a redirect to another site can't be blocked: Claude is only told not to follow one. "
            + "You make the click that shows a secret and close that page before Send; while it is open, "
            + "Claude could read it. A secret you paste into the card goes straight to Watchtower; "
            + "Claude never gets it.")
        let words = slack(.empty, harness: codex, browser: false).helpText
        #expect(words == "Codex tells you each step and checks it; you do the clicks in your browser. "
            + "A secret you paste into the card goes straight to Watchtower; Codex never gets it.")
    }

    @Test("the entry points' agent buttons name the harness; today's path is the quiet link")
    func agentButtons() {
        #expect(Pres.connectWith(claude) == "Connect with Claude")
        #expect(Pres.setUpCompanyWith(claude) == "Set up for my company with Claude")
        #expect([Pres.connectByHand, Pres.reconnectByHand] == ["Connect", "Reconnect"])
        #expect([Pres.companyName, Pres.ownGoogleProjectName] == ["your company", "your Google project"])
        #expect(Pres(service: Pres.companyName, harness: claude, mode: .browser, state: .empty).title
            == "Connect your company")
    }

    @Test("the onboarding footnote names the harness only when one is offered")
    func onboardingFootnote() {
        #expect(Pres.onboardingFootnote(nil)
            == "Everything stays on your Mac. Connect opens the same sheet as in Settings.")
        #expect(Pres.onboardingFootnote(claude)
            == "Everything stays on your Mac. Claude walks you through each sign-in; "
            + "Connect opens the same sheet as in Settings.")
    }

    @Test("confirm cards: the customer presses them, never the model")
    func confirm() {
        guard case .confirm(let pkce) = slack(.confirm(.slackPKCE)).card,
              case .confirm(let publish) = slack(.confirm(.companyPublish(company: "Acme"))).card
        else { Issue.record("no confirm card"); return }
        #expect(pkce.question == "Turn on PKCE for the Slack app?")
        #expect(pkce.detail == "This can't be undone.")
        #expect(pkce.footnote == "Only you can press this — Claude can't.")
        #expect([pkce.confirm, pkce.cancel] == ["Confirm", "Cancel"])
        #expect(publish.question == "Publish the setup for Acme?")
        #expect(publish.detail == "Everyone at Acme will see the Slack app's new About text.")

        let changes = ["Add scopes: reactions:read", "Turn on PKCE sign-in"]
        guard case .confirm(let update) = slack(.confirm(.slackUpdate(changes: changes, pkce: true))).card,
              case .confirm(let same) = slack(.confirm(.slackUpdate(changes: [], pkce: false))).card
        else { Issue.record("no update card"); return }
        #expect(update.question == "Update the company's Slack app?")
        #expect(update.detail == "Add scopes: reactions:read. Turn on PKCE sign-in. PKCE can't be turned off again.")
        #expect(same.question == "No changes; adopt this app?")
        #expect(same.detail == "Its settings already match Watchtower's.")
    }

    @Test("a secret card names where the value goes; a fixed place shows no line")
    func secretDestination() {
        guard case .secret(let mail) = slack(.secret(label: "Password",
                                                     destination: "imap.example.com:993 (ssl) as alice@example.com")).card,
              case .secret(let fixed) = slack(.secret(label: "Token")).card
        else { Issue.record("no secret card"); return }
        #expect(mail.destination == "Sends it to imap.example.com:993 (ssl) as alice@example.com")
        #expect(fixed.destination == nil)
        #expect(Pres.mailDestination(host: "imap.example.com", port: 993, security: "ssl", username: "alice@example.com")
            == "imap.example.com:993 (ssl) as alice@example.com")
        #expect(Pres.calendarDestination(url: "https://dav.example.com/", username: "alice")
            == "https://dav.example.com/ as alice")
        #expect(Pres.headerDestination(header: "X-Api-Key", url: "https://mcp.example.com/mcp")
            == "the X-Api-Key header of https://mcp.example.com/mcp")
        #expect(Pres.variableDestination(variable: "API_KEY", commandLine: "npx -y acme-mcp")
            == "the API_KEY variable of npx -y acme-mcp")
    }

    @Test("a confirm card shows exactly what it applies to")
    func confirmSubject() {
        func card(_ confirm: ConnectAssistantConfirm) -> Pres.ConfirmCard? {
            guard case .confirm(let card) = slack(.confirm(confirm)).card else { return nil }
            return card
        }
        let command = card(.quickConnection(name: "docs", server: .command("npx -y acme-mcp --read-only")))
        #expect(command?.question == "Turn on the docs connection?")
        #expect(command?.subject == "Runs: npx -y acme-mcp --read-only")
        #expect(command?.detail == "Watchtower will run this command, and the assistant will be able to use its tools.")
        let url = card(.quickConnection(name: "docs", server: .url("https://mcp.example.com/mcp")))
        #expect(url?.subject == "Connects to: https://mcp.example.com/mcp")
        #expect(url?.detail
            == "Watchtower will connect to this server, and the assistant will be able to use its tools.")
        let google = card(.ownGoogleClient(clientID: "1234-acme.apps.googleusercontent.com"))
        #expect(google?.subject == "Client ID: 1234-acme.apps.googleusercontent.com")
        #expect(google?.question == "Use your own Google project to sign in?")
        let publish = card(.companyPublish(company: "Acme", services: ["Slack", "Google Workspace"]))
        #expect(publish?.subject == "Publishes: Slack, Google Workspace")
        #expect(card(.companyPublish(company: "Acme"))?.subject == nil)
        #expect(card(.slackPKCE)?.subject == nil)
        #expect(card(.companyReplace(company: "Acme"))?.subject == nil)
    }

    @Test("done counts the service's accounts in its own word")
    func done() {
        #expect(slack(.done(accounts: 2, noun: .workspace)).status
            == .init(kind: .success, text: "Slack is connected — 2 workspaces"))
        let jira = Pres(service: "Jira", harness: codex, mode: .browser, state: .done(accounts: 1, noun: .site))
        #expect(jira.status?.text == "Jira is connected — 1 site")
        #expect(jira.actions.isEmpty)
    }
}

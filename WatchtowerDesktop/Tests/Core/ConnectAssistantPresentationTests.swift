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

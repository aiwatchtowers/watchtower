import Foundation

/// Whether the agent drives the browser itself or tells the customer each step (§5.2).
package enum ConnectAssistantMode: Equatable, Sendable {
    case browser
    case words
}

/// Why a run failed (§7, §8): every one offers **Retry** and **Set up by hand**.
package enum ConnectAssistantFailure: Equatable, Sendable {
    /// The agent stopped on its own; `reason` is its last words, if any.
    case agent(reason: String?)
    /// The harness's usage limit; the header's picker switches harness.
    case quota
    /// The harness CLI is not installed or does not start.
    case harnessMissing
    /// The customer did not finish a browser step within the run's wait.
    case timedOut
}

/// A step only the customer may press (§5.3, §5.4): the model cannot.
package enum ConnectAssistantConfirm: Equatable, Sendable {
    case slackPKCE
    case ownGoogleClient
    case quickConnection(name: String)
    case companyPublish(company: String)
    case companyReplace(company: String)
}

/// One state of the connect assistant panel (§7).
package enum ConnectAssistantState: Equatable, Sendable {
    /// Just opened: the invitation and **Start**.
    case empty
    /// The agent is working.
    case thinking
    /// The agent waits on the customer in the browser; `step` is what they must do,
    /// e.g. "press Allow in Slack".
    case waiting(step: String)
    case failed(ConnectAssistantFailure)
    /// Another connect of this service runs elsewhere.
    case busy
    /// The secure field card; `label` is the agent's (≤ 80 characters, §5.3).
    case secret(label: String)
    case confirm(ConnectAssistantConfirm)
    /// `accounts` is the service's connected-account count after the run.
    case done(accounts: Int, noun: ConnectAssistantAccountNoun)
}

/// What one connected account of a service is called in the done line.
package enum ConnectAssistantAccountNoun: Sendable {
    case account, workspace, site

    package func counted(_ count: Int) -> String {
        let word = switch self {
        case .account: "account"
        case .workspace: "workspace"
        case .site: "site"
        }
        return "\(count) \(word)\(count == 1 ? "" : "s")"
    }
}

/// One line of the assistant's chat (fixture or live).
package struct ConnectAssistantLine: Equatable, Sendable {
    package enum Role: Sendable { case assistant, customer }

    package let role: Role
    package let text: String

    package init(_ role: Role, _ text: String) {
        self.role = role
        self.text = text
    }
}

/// Every string of the connect assistant panel (agent connect spec §7):
/// the header, the mode line, each state's status line, the secret and
/// confirm cards and the buttons.
package struct ConnectAssistantPresentation: Equatable, Sendable {
    package enum Action: Equatable, Sendable {
        case start, guideInWords, retry, setUpByHand, openIt, cancel

        package var title: String {
            switch self {
            case .start: "Start"
            case .guideInWords: "Guide me in words"
            case .retry: "Retry"
            case .setUpByHand: "Set up by hand"
            case .openIt: "Open it"
            case .cancel: "Cancel"
            }
        }
    }

    /// The status line under the chat: what is happening right now.
    package struct Status: Equatable, Sendable {
        package enum Kind: Sendable { case progress, problem, success }

        package let kind: Kind
        package let text: String
    }

    /// The secure field card (§5.3): its value goes to the Desktop flow, never to the chat.
    package struct SecretCard: Equatable, Sendable {
        package let label: String
        package var placeholder = "Paste it here"
        package let footnote: String
        package var send = "Send"
    }

    /// A step only the customer may press (§5.3).
    package struct ConfirmCard: Equatable, Sendable {
        package let question: String
        package let detail: String
        package let footnote: String
        package var confirm = "Confirm"
        package var cancel = Action.cancel.title
    }

    package enum Card: Equatable, Sendable {
        case secret(SecretCard)
        case confirm(ConfirmCard)
    }

    package let title: String
    package let harness: String
    package let modeLine: String
    /// The agent tells each step instead of driving the browser.
    package let wordsOnly: Bool
    /// The assistant's opening line, shown above the chat until a run starts.
    package let intro: String?
    package let status: Status?
    package let card: Card?
    /// In order; the first is the panel's one prominent action.
    package let actions: [Action]
    package let composerPlaceholder: String

    package static let composerPlaceholder = "Ask a question…"
    package static let close = "Close the assistant"
    package static let switchHarness = "Switch the assistant"

    /// - Parameters:
    ///   - service: the connector's display name ("Slack").
    ///   - browserAvailable: false when the harness's browser is not detected (no extension, §10 S1);
    ///     the panel then runs in words only. A harness whose capability is not `.browser` never has one.
    package init(
        service: String,
        harness: ConnectHarness,
        mode: ConnectAssistantMode,
        browserAvailable: Bool = true,
        state: ConnectAssistantState
    ) {
        let browserAvailable = browserAvailable && harness.capability == .browser
        let words = mode == .words || !browserAvailable
        title = "Connect \(service)"
        self.harness = harness.name
        modeLine = Self.modeLine(harness: harness, words: words)
        wordsOnly = words
        composerPlaceholder = Self.composerPlaceholder
        var intro: String?
        var status: Status?
        var card: Card?
        var actions: [Action] = []
        switch state {
        case .empty:
            if browserAvailable {
                intro = "I'll connect \(service) with you. Start?"
                actions = words ? [.start, .setUpByHand] : [.start, .guideInWords, .setUpByHand]
            } else {
                intro = "I'll connect \(service) with you. "
                    + Self.noBrowser(harness) + " I'll tell you each step and check it. Start?"
                actions = [.start, .setUpByHand]
            }
        case .thinking:
            status = Status(kind: .progress, text: "Working on it…")
            actions = [.cancel]
        case .waiting(let step):
            status = Status(kind: .progress, text: "Waiting for you to \(step)")
            actions = [.cancel]
        case .failed(let failure):
            status = Status(kind: .problem, text: Self.failure(failure, harness: harness, service: service))
            actions = [.retry, .setUpByHand]
        case .busy:
            status = Status(kind: .problem, text: "\(service) is already connecting in another window")
            actions = [.openIt]
        case .secret(let label):
            card = .secret(SecretCard(label: label, footnote: Self.secretFootnote(harness)))
        case .confirm(let confirm):
            let (question, detail) = Self.confirm(confirm)
            card = .confirm(ConfirmCard(question: question, detail: detail,
                                        footnote: "Only you can press this — \(harness.name) can't."))
        case let .done(accounts, noun):
            status = Status(kind: .success, text: "\(service) is connected — \(noun.counted(accounts))")
        }
        self.intro = intro
        self.status = status
        self.card = card
        self.actions = actions
    }

    package static func modeLine(harness: ConnectHarness, words: Bool) -> String {
        words ? "I'll tell you each step" : "Using \(harness.name) in Chrome"
    }

    /// The secret card's footnote: the value never reaches the model (§5.3, §6).
    package static func secretFootnote(_ harness: ConnectHarness) -> String {
        "Goes straight to Watchtower — \(harness.name) doesn't see it"
    }

    /// Why the run is in words: a browser harness whose browser is not
    /// detected, or a harness that cannot drive one.
    private static func noBrowser(_ harness: ConnectHarness) -> String {
        switch harness.capability {
        case .browser: "\(harness.name) in Chrome isn't connected, so I can't use your browser."
        case .words, .none: "\(harness.name) can't use your browser yet."
        }
    }

    private static func failure(
        _ failure: ConnectAssistantFailure,
        harness: ConnectHarness,
        service: String
    ) -> String {
        switch failure {
        case .agent(let reason):
            guard let reason, !reason.isEmpty else { return "\(harness.name) stopped before \(service) was connected." }
            return "\(harness.name) stopped: \(reason)"
        case .quota:
            return "\(harness.name) has reached its usage limit. Retry later or switch the assistant above."
        case .harnessMissing:
            return "\(harness.name) isn't installed on this Mac. Switch the assistant above or set up by hand."
        case .timedOut:
            return "I stopped waiting after 15 minutes. Press Retry when you're ready."
        }
    }

    private static func confirm(_ confirm: ConnectAssistantConfirm) -> (String, String) {
        switch confirm {
        case .slackPKCE:
            ("Turn on PKCE for the Slack app?", "This can't be undone.")
        case .ownGoogleClient:
            ("Use your own Google project to sign in?", "Watchtower will trust the client you created.")
        case .quickConnection(let name):
            ("Turn on the \(name) connection?", "The assistant will be able to use its tools.")
        case .companyPublish(let company):
            ("Publish the setup for \(company)?", "Everyone at \(company) will see the Slack app's new About text.")
        case .companyReplace(let company):
            ("Replace the stored setup for \(company)?", "Accounts on the old apps will need to sign in again.")
        }
    }
}

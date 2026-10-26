import Foundation

/// What the app holds that the Learn selector reads besides the database
/// rows (design §9.6): the sources, the features, the phone, dictation.
package struct LearnAppState: Equatable, Sendable {
    /// Read from the account tables with the seen rows, never the sidebar's
    /// fail-open `.all`: a signal writes a permanent `in_use` row.
    package var connected: ConnectedSources
    /// The disabled feature ids; nil until `features list` first loaded
    /// (the fail-open empty set must not read as "memory on").
    package var disabledFeatures: Set<String>?
    package var iphonePaired: Bool
    package var dictationUsed: Bool

    package init(
        connected: ConnectedSources = .none,
        disabledFeatures: Set<String>? = nil,
        iphonePaired: Bool = false,
        dictationUsed: Bool = false
    ) {
        self.connected = connected
        self.disabledFeatures = disabledFeatures
        self.iphonePaired = iphonePaired
        self.dictationUsed = dictationUsed
    }
}

/// The selector's signals and met requirements from the app's state. Pure.
package enum LearnInputs {
    /// `UserDefaults` flag `DictationCenter` sets on a finished dictation
    /// with text (`dictation.used`); per install.
    package static let dictationUsedKey = "learn.dictationUsed"

    /// `rowSignals` plus the signals the app's state gives.
    package static func signals(rows: Set<LearnSignal>, app: LearnAppState) -> Set<LearnSignal> {
        var signals = rows
        if let disabled = app.disabledFeatures, !disabled.contains("memory") { signals.insert(.memoryOn) }
        if app.connected.calendar { signals.insert(.calendarConnected) }
        if app.connected.jira { signals.insert(.jiraConnected) }
        if app.connected.linear { signals.insert(.linearConnected) }
        if app.iphonePaired { signals.insert(.iphonePaired) }
        if app.dictationUsed { signals.insert(.dictationUsed) }
        return signals
    }

    /// The `requires` values of `catalog` that hold now. A feature counts as
    /// on until `features list` loaded (fail-open, like the sidebar): a
    /// requirement only changes a button, never writes a row.
    package static func metRequirements(
        _ catalog: LearnCatalog, signals: Set<LearnSignal>, app: LearnAppState
    ) -> Set<String> {
        Set(catalog.cards.map(\.requires).filter { requirement in
            let (kind, value) = split(requirement)
            switch kind {
            case "feature": return !(app.disabledFeatures ?? []).contains(value)
            case "source": return sourceConnected(value, signals: signals, connected: app.connected)
            default: return false
            }
        })
    }

    /// The `internal/learn` sources (`learn.sources`); Google counts with
    /// Gmail or its calendar on, IMAP with any mail.
    static func sourceConnected(_ source: String, signals: Set<LearnSignal>, connected: ConnectedSources) -> Bool {
        switch source {
        case "slack": connected.slack
        case "google": connected.mail || connected.calendar
        case "imap": connected.mail
        case "calendar": connected.calendar
        case "jira": connected.jira
        case "linear": connected.linear
        case "confluence": signals.contains(.confluenceConnected)
        default: false
        }
    }

    static func split(_ value: String) -> (String, String) {
        guard let colon = value.firstIndex(of: ":") else { return (value, "") }
        return (String(value[..<colon]), String(value[value.index(after: colon)...]))
    }
}

/// A card's main button (design §9.2): its `action`, Turn on / Connect while
/// its `requires` is missing, else Read more.
package enum LearnPrimary: Equatable, Sendable {
    /// A `watchtower-nav` screen.
    case nav(screen: String)
    /// An `internal/learn` source name.
    case connect(source: String)
    case turnOn(featureID: String)
    /// The popup with the prompt in its composer.
    case chat(prompt: String)
    /// Shows the key; pressing it only records the card seen.
    case hotkey(label: String)
    case readMore

    package init(_ pick: LearnPick) {
        let card = pick.card
        if !pick.requirementMet {
            let (kind, value) = LearnInputs.split(card.requires)
            self = kind == "feature" ? .turnOn(featureID: value) : .connect(source: value)
            return
        }
        let (kind, value) = LearnInputs.split(card.action)
        switch kind {
        case "nav": self = .nav(screen: value)
        case "connect": self = .connect(source: value)
        case "turnOn": self = .turnOn(featureID: value)
        case "chat": self = .chat(prompt: value)
        case "hotkey": self = .hotkey(label: card.hotkeyLabel.isEmpty ? value : card.hotkeyLabel)
        default: self = .readMore
        }
    }

    /// The button's text; `screenTitle` names a `nav` screen (the sidebar's
    /// titles live in the app), nil = the raw name.
    package func title(screenTitle: (String) -> String?) -> String {
        switch self {
        case .nav(let screen): "Open \(screenTitle(screen) ?? screen)"
        case .connect(let source): "Connect \(Self.sourceName(source))"
        case .turnOn: "Turn on"
        case .chat: "Try in chat"
        case .hotkey(let label): "Try \(label)"
        case .readMore: "Read more"
        }
    }

    static func sourceName(_ source: String) -> String {
        switch source {
        case "slack": "Slack"
        case "google": "Google"
        case "imap": "Email"
        case "calendar": "Calendar"
        case "jira": "Jira"
        case "linear": "Linear"
        case "confluence": "Confluence"
        default: source.capitalized
        }
    }

    /// The Settings → Connections service a source opens (`ConnectionService`
    /// raw values): IMAP is Email, Confluence lives under its Jira account.
    package static func connectionService(_ source: String) -> String {
        switch source {
        case "imap": "email"
        case "confluence": "jira"
        default: source
        }
    }
}

extension LearnCard {
    /// Read more: the card's guide section; nil without a page.
    package var guideURL: URL? {
        page.isEmpty ? nil : GuideLinks.url(path: page, anchor: anchor)
    }

    /// Ask about this: the popup's composer text.
    package var askPrompt: String {
        "How do I use \(title)?"
    }
}

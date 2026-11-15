import Foundation
import WatchtowerSync

/// The phone's word for a hub (#1783): a **tower** — a Mac running the
/// Watchtower app or a server running the headless hub. Every screen says
/// the hub's name where it has one ("Acme Mac is asleep") and "your tower"
/// where it has none. The only "Mac" left on screen lives in this file: the
/// steps that point into the Mac app's menus (shown only for a Mac hub,
/// `TowerHost`) and the pairing line that explains the word once.
/// `TowerWordGuardTests` fails on a new "Mac" anywhere else.
enum TowerText {
    static let word = "tower"
    static let plural = "towers"
    static let title = "Tower"
    static let pluralTitle = "Towers"

    /// The hub's name in a sentence, "your tower" when it has none yet.
    static func name(_ hubName: String) -> String { hubName.isEmpty ? "your tower" : hubName }
    /// The same at the start of a sentence: "Your tower" when it has no name.
    static func sentenceName(_ hubName: String) -> String { hubName.isEmpty ? "Your tower" : hubName }
    /// A label on its own (a row, a chip): "Tower" when it has no name.
    static func label(_ hubName: String) -> String { hubName.isEmpty ? title : hubName }
}

/// Pairing (Welcome, Scan, The tower doesn't show up): the phone does not
/// know yet what it links to, so these say once what a tower is and give the
/// step for both kinds.
enum PairingText {
    /// The one explanation of the word.
    static let explainer = "your Mac or server running Watchtower"
    static let welcomeTagline = "Asks, sessions, the board and your meetings from your tower — \(explainer)."
    static let welcomeSteps = "On a Mac: Settings → Mobile → Use Watchtower on iPhone.\nOn a server: watchtower hub pair."
    static let scanButton = "Scan the code on your tower"
    static let notShowingLink = "The tower doesn't show up"

    static let macTitle = "On a Mac"
    static let macChecklist = [
        "Watchtower is open on the Mac",
        "Settings → Mobile is on",
        "The Mac is awake",
        "It is a signed build",
        "iCloud is on"
    ]
    static let macFooter = "Then choose Use Watchtower on iPhone in Settings → Mobile on the Mac, and scan the code it shows."
    static let serverTitle = "On a server"
    static let serverChecklist = [
        "The Watchtower service is running",
        "This iPhone has Relay"
    ]
    static let serverFooter = "Then run watchtower hub pair in a terminal on it, and scan the code it prints."
}

/// What runs the hub, as far as its instructions go (#1783): the Watchtower
/// app's menus exist only on a Mac; a server takes the same answers through
/// `watchtower hub allow`. An older hub that sends no kind is a Mac; a kind
/// this build does not know is not (`HeartbeatPayload.isMac`). Before the
/// first heartbeat the phone reads a Mac, today's wording.
enum TowerHost: Equatable {
    case mac
    /// `device` is this iPhone's id as `watchtower hub phones` lists it (its grant's device id), nil before the
    /// tower's grant reached the phone.
    case server(device: String?)

    init(_ heartbeat: HeartbeatPayload?, device: String?) {
        self = heartbeat?.isMac ?? true ? .mac : .server(device: device?.uppercased())
    }

    /// The command a server tower runs to give this phone `grant`, with this iPhone's real id when the phone
    /// has it; without it, where to find the id.
    static func allowCommand(_ grant: String, device: String?) -> String {
        guard let device, !device.isEmpty else {
            return "watchtower hub phones (find this iPhone's id), then watchtower hub allow <id> \(grant)"
        }
        return "watchtower hub allow \(device) \(grant)"
    }

    /// The typing hint while the grant is missing.
    var typingWait: String {
        switch self {
        case .mac: "Waiting for your Mac to allow typing: Watchtower → Settings → Mobile → Allow…"
        case let .server(device):
            "Waiting for your tower to allow typing. On it, run:\n\(Self.allowCommand("typing", device: device))"
        }
    }

    /// The permission card's hint while the grant is missing.
    var permissionsWait: String {
        switch self {
        case .mac: "Allow answering permission prompts on the Mac: Watchtower → Settings → Mobile → Allow…"
        case let .server(device):
            "Allow answering permission prompts on your tower. On it, run:\n\(Self.allowCommand("permissions", device: device))"
        }
    }

    /// Settings' Starting sessions caption while it is not allowed.
    var startSessionsAllow: String {
        switch self {
        case .mac: "Allow it on your Mac: Watchtower → Settings → Mobile, after typing"
        case let .server(device):
            "Allow it on your tower, after typing:\n\(Self.allowCommand("start_sessions", device: device))"
        }
    }

    /// The start sheet's window switch: only a Mac has a window to bring forward.
    var bringForwardTitle: String? {
        switch self {
        case .mac: "Bring the window forward on the Mac"
        case .server: nil
        }
    }

    /// Why this phone may not start a session or run an automation: `what` is "start sessions" or "run automations".
    func notAllowed(_ what: String) -> String {
        switch self {
        case .mac:
            "Your Mac has not allowed this phone to \(what). "
                + "On the Mac: Watchtower → Settings → Mobile → allow typing, then starting sessions."
        case let .server(device):
            "Your tower has not allowed this phone to \(what). On it, run:\n"
                + Self.allowCommand("typing", device: device) + "\n" + Self.allowCommand("start_sessions", device: device)
        }
    }
}

/// The Chats tab's lines that name the hub (iPhone chat spec §6.1, mockups 1a–1j): the spec's own copy on a Mac
/// hub, "your tower" on a server (#1783). Lines that never name the hub live in the chat models.
enum ChatText {
    static func updateTitle(_ host: TowerHost) -> String {
        host == .mac ? "Update Watchtower on your Mac" : "Update Watchtower on your tower"
    }

    static func updateLine(_ host: TowerHost) -> String {
        host == .mac ? "This Mac's Watchtower is too old for chat on the phone." : "This tower's Watchtower is too old for chat on the phone."
    }

    /// Only a Mac hub runs over iCloud: a server is on Relay or nowhere.
    static let relayLine = "This Mac talks to your phone through iCloud. Chat needs Relay, which streams the answer as it is written."
    static let macAllowLine = "On the Mac: Settings → Mobile → this phone → allow Chat."

    static func unavailableLine(_ host: TowerHost) -> String {
        host == .mac
            ? "Watchtower on your Mac could not start chat. Restart Watchtower there to try again."
            : "Watchtower on your tower could not start chat. Restart the Watchtower service there to try again."
    }

    static func loading(_ host: TowerHost) -> String {
        host == .mac ? "Getting your chats from the Mac…" : "Getting your chats from your tower…"
    }

    static func readFailed(_ host: TowerHost) -> String {
        host == .mac ? "The Mac could not read its chats." : "Your tower could not read its chats."
    }

    static func emptyLine(_ host: TowerHost) -> String {
        let who = host == .mac ? "Your Mac" : "Your tower"
        return "Ask anything about your Slack, mail, Jira, meetings and work. \(who) answers with everything it knows."
    }

    static func asleep(_ host: TowerHost) -> String {
        "\(host == .mac ? "Your Mac" : "Your tower") is asleep. You can read chats; sending works when it wakes."
    }

    static func offline(_ host: TowerHost) -> String {
        "\(host == .mac ? "Your Mac" : "Your tower") is offline. You can read chats; sending works when it is back."
    }

    static func searching(_ host: TowerHost) -> String {
        host == .mac ? "Searching on your Mac…" : "Searching on your tower…"
    }

    static func searchNeedsHub(_ host: TowerHost) -> String {
        host == .mac ? "Searching messages needs your Mac" : "Searching messages needs your tower"
    }

    static func noAnswer(_ host: TowerHost) -> String {
        host == .mac ? "The Mac did not answer" : "Your tower did not answer"
    }
}

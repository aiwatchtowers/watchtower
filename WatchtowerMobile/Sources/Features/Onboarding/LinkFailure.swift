/// Why a scan did not link (spec §2.3), with the text the phone shows.
enum LinkFailure: Equatable {
    case expired
    case signIn
    case cannotShare
    case noAnswer
    /// The Mac refused the code, or it cannot be read.
    case refused
    case updateApp
    /// The code is from an older Mac (a `LinkPayload` version below the
    /// phone's): its zones are not the ones this phone syncs.
    case updateMac
    /// iCloud failed under the flow (a reason from CloudKit).
    case iCloud(String)
    /// This iPhone could not set its sync up (the local replica or the
    /// transport's store): nothing reached iCloud.
    case local(String)
    /// `HubRegistry.limit` Macs are linked and the code is another one's.
    case tooManyMacs
    /// A hub that works over Relay only (a headless host), and this iPhone cannot use Relay.
    case needsRelay(macName: String)
    /// The relay did not answer whether this iPhone may use it (unreachable, an attestation backoff).
    case relayUnreachable
    /// The Mac runs over Relay and this iPhone cannot use Relay: an iCloud link would get no updates from it.
    case macOnRelay(macName: String)
    /// `NOT_FOUND` at `open_pairing`: the Mac has not registered on the relay yet (ask #914, proposed default).
    case macNotOnRelay(macName: String)

    /// What went wrong, as the failure screen's title (design pass O3).
    var title: String {
        switch self {
        case .expired: "This code expired"
        case .signIn: "Sign in to iCloud on this iPhone"
        case .cannotShare: "This Mac can't share with another Apple ID right now"
        case .noAnswer: "Your Mac didn't answer"
        case .refused: "This code can't be used"
        case .updateApp: "Update Watchtower on this iPhone"
        case .updateMac: "Update Watchtower on this Mac"
        case .iCloud: "Couldn't reach iCloud"
        case .local: "Couldn't set up sync on this iPhone"
        case .tooManyMacs: "You can link up to \(HubRegistry.limit) Macs"
        case let .needsRelay(macName): "\(macName) works over Relay only"
        case .relayUnreachable: "Couldn't reach Relay"
        case let .macOnRelay(macName): "\(macName) runs over Relay"
        case let .macNotOnRelay(macName): "\(macName) isn't on Relay yet"
        }
    }

    /// What to do about it, under the title; nil when the title says it all.
    var hint: String? {
        switch self {
        case .expired, .cannotShare, .refused: "Show a new code on the Mac"
        case .signIn: "Watchtower uses iCloud to reach your Mac"
        case .noAnswer: "Keep Settings → Mobile open on the Mac and scan again"
        case .updateApp, .updateMac: nil
        case .tooManyMacs: "Unlink one in Settings → Macs, then scan again"
        case .needsRelay: "Relay isn't available on this iPhone"
        case .relayUnreachable: "Check your connection and scan again"
        case .macOnRelay: Self.macOnRelayHint
        case .macNotOnRelay: "Open Watchtower on the Mac and try again"
        case let .iCloud(reason), let .local(reason): reason.isEmpty ? nil : reason
        }
    }

    /// One line, "title — hint", for any reader other than the failure
    /// screen; signIn, updateApp and updateMac keep their earlier text.
    var message: String {
        switch self {
        case .signIn: "Sign in to iCloud on this iPhone to use Watchtower"
        case .updateApp, .updateMac: title
        default: hint.map { "\(title) — \($0)" } ?? title
        }
    }

    /// Why a Mac on Relay is not linked over iCloud (the failure screen and the never-live link's notice).
    static let macOnRelayHint = "This iPhone can't use Relay, so it would get no updates from it. Link it when the Mac is back on iCloud."

    /// The failure screen's one colour: its icon, never orange (spec §14).
    var toneUses: [ToneUse] {
        [ToneUse(element: "link failure icon", tone: .secondary, role: .info)]
    }

    /// The same code again (the Mac may come online meanwhile); nil when only a new scan helps.
    var retryTitle: String? {
        if case .macNotOnRelay = self { return "Try Again" }
        return nil
    }

    /// Scanning another code can help (it cannot while iCloud is signed
    /// out, the app is too old, or every Mac slot is taken).
    var offersScan: Bool {
        switch self {
        // A Mac not on Relay yet: the same code once more (Try Again), not a new scan.
        case .signIn, .updateApp, .tooManyMacs, .macNotOnRelay: false
        default: true
        }
    }
}

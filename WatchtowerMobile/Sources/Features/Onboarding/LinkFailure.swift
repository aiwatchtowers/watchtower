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
        }
    }

    /// What to do about it, under the title; nil when the title says it all.
    var hint: String? {
        switch self {
        case .expired, .cannotShare, .refused: "Show a new code on the Mac"
        case .signIn: "Watchtower uses iCloud to reach your Mac"
        case .noAnswer: "Keep Settings → Mobile open on the Mac and scan again"
        case .updateApp, .updateMac: nil
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

    /// Scanning another code can help (it cannot while iCloud is signed
    /// out or the app is too old).
    var offersScan: Bool {
        switch self {
        case .signIn, .updateApp: false
        default: true
        }
    }
}

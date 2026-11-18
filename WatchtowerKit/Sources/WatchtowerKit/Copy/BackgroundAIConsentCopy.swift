import WatchtowerSync

/// The phone's side of the background AI consent (#1886, spec §6.5). The phone cannot allow it: the line only says
/// where to. The Desktop's `BackgroundAIConsentCopy` holds the same two strings for its design shots.
public enum BackgroundAIConsentCopy {
    static let pausedLine = "Digests and briefings aren't updating: background AI is paused on your Mac. Allow it in Watchtower on the Mac."
    static let organizationLine = "Digests and briefings aren't updating: your organization turned background AI off."

    /// The line for the Mac's status; nil while it is allowed and for an older hub that sends none.
    public static func phoneLine(_ status: BackgroundAIStatus?) -> String? {
        switch status {
        case .paused: pausedLine
        case .organization: organizationLine
        case .allowed, nil: nil
        }
    }
}

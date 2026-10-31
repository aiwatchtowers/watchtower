import Foundation

/// What the pairing QR carries so the phone can join a hub (today's
/// `data_share` / `relay_share`). On CloudKit these are the two `CKShare.url`
/// strings.
public struct LinkInvitation: Equatable, Sendable {
    public let dataShare: String?
    public let relayShare: String?

    public init(dataShare: String?, relayShare: String?) {
        self.dataShare = dataShare
        self.relayShare = relayShare
    }

    public static let none = Self(dataShare: nil, relayShare: nil)
}

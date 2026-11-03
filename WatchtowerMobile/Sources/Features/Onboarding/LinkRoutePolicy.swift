import Foundation
import WatchtowerHostedRelay
import WatchtowerSync

/// Which way a scanned code links (relay client Phase 3, R4).
enum LinkRoute: Equatable {
    /// iCloud, as before the relay.
    case cloudKit
    /// A relay pairing slot with the Mac `mac` (its relay device id), vouched for with `authPub` (its `relay_auth`
    /// public key, raw bytes).
    case relay(mac: String, authPub: Data)
    /// No link: the failure screen.
    case refuse(LinkFailure)
}

/// The link route rule (R4), pure. A code whose hub is on iCloud (v3; v4 with `transport` absent or `cloudkit`)
/// links over iCloud. A code whose hub runs over Relay links over a pairing slot when this phone may use Relay,
/// and is refused otherwise: an iCloud link to a Mac on Relay would only ever receive `hub_on_relay`.
enum LinkRoutePolicy {
    /// `paying` is asked only when the code's hub is on the relay and the relay is available. An answer that is not
    /// a definite yes or no (unreachable, an attestation backoff) refuses with `.relayUnreachable`: it is never read
    /// as "not paying", so a paying phone is never sent to iCloud.
    static func decide(
        _ code: LinkPayload,
        relay: RelayAvailability,
        paying: () async -> Result<Bool, HostedRelayPairing.Refusal>
    ) async -> LinkRoute {
        let onRelay = code.transport == .relay || (code.transport == nil && !code.offersCloudKit && code.offersRelay)
        guard onRelay else {
            // A code that names no route this phone can use (a v4 code with neither iCloud nor a relay identity).
            return code.offersCloudKit ? .cloudKit : .refuse(.refused)
        }
        guard code.offersRelay, let mac = code.relayDeviceID,
              let authPub = code.relayAuthPub.flatMap(WireBytes.fromBase64URL) else { return .refuse(.refused) }
        // A Mac on Relay that also offers iCloud is a Mac switched to Relay; one that does not is a headless host.
        let cannotUse: LinkRoute = .refuse(code.offersCloudKit ? .macOnRelay(macName: code.macName) : .needsRelay(macName: code.macName))
        guard case .available = relay else { return cannotUse }
        switch await paying() {
        case .success(true): return .relay(mac: mac, authPub: authPub)
        case .success(false), .failure(.notPaying): return cannotUse
        case .failure(.updateRequired): return .refuse(.updateApp)
        case .failure: return .refuse(.relayUnreachable)
        }
    }

    /// The paying check over the relay's account state. Only `.updateRequired` keeps its meaning; every other
    /// failure, mapped or not, is transient (`.unreachable`).
    static func paying(_ accountState: () async throws -> (paying: Bool, macs: [String])) async -> Result<Bool, HostedRelayPairing.Refusal> {
        do {
            return .success(try await accountState().paying)
        } catch HostedRelayPairing.Refusal.updateRequired {
            return .failure(.updateRequired)
        } catch HostedRelayPairing.Refusal.notPaying {
            return .success(false)
        } catch {
            return .failure(.unreachable)
        }
    }
}

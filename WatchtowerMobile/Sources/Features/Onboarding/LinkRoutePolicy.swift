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

/// The link route rule (R4; #2191), pure. A code *offers Relay* when its relay identity is coherent and its
/// `transports` lists `relay` (a code without `transports` goes by the identity alone). In order:
///
/// | Code | Relay on this phone | Paying answer | Route |
/// |---|---|---|---|
/// | offers Relay | available | yes | `.relay` (also for a hub on iCloud) |
/// | offers Relay | available | none (unreachable, backoff), device entitled | `.refuse(.relayUnreachable)` |
/// | hub on iCloud | available | none, device not entitled | `.cloudKit` |
/// | offers Relay | available | `.updateRequired` | `.refuse(.updateApp)` |
/// | hub on iCloud | off, or not paying | — | `.cloudKit` |
/// | hub on Relay | off, or not paying | — | `.macOnRelay` / `.needsRelay` |
/// | neither route | — | — | `.refuse(.refused)` |
///
/// An iCloud link to a Mac on Relay would only ever receive `hub_on_relay`, so a hub on Relay is never linked over
/// iCloud.
enum LinkRoutePolicy {
    /// `paying` is asked only when the code offers Relay and the relay is available. On a hub on Relay, an answer that
    /// is not a definite yes or no refuses with `.relayUnreachable`: it is never read as "not paying". On a hub on
    /// iCloud it does so only when `entitled` (the device's StoreKit entitlement, read only then) says this phone
    /// pays; otherwise the phone links over iCloud as before.
    static func decide(
        _ code: LinkPayload,
        relay: RelayAvailability,
        entitled: () async -> Bool = { false },
        paying: () async -> Result<Bool, HostedRelayPairing.Refusal>
    ) async -> LinkRoute {
        let offersRelay = code.offersRelay && (code.transports.map { $0.contains("relay") } ?? true)
        let onRelay = code.transport == .relay || (code.transport == nil && !code.offersCloudKit && code.offersRelay)
        guard onRelay else {
            guard code.offersCloudKit else {
                // A code that names no route this phone can use (a v4 code with neither iCloud nor a relay identity).
                return .refuse(.refused)
            }
            guard offersRelay, case .available = relay, let mac = code.relayDeviceID,
                  let authPub = code.relayAuthPub.flatMap(WireBytes.fromBase64URL) else { return .cloudKit }
            switch await paying() {
            case .success(true): return .relay(mac: mac, authPub: authPub)
            case .success(false), .failure(.notPaying): return .cloudKit
            case .failure(.updateRequired): return .refuse(.updateApp)
            case .failure: return await entitled() ? .refuse(.relayUnreachable) : .cloudKit
            }
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

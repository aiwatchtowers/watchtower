import Foundation
import WatchtowerRelayProto

/// What a test may break on the fake only (R15): op failures, refused dials, deploys,
/// displacement, a crash, missing pongs, an unanswered subscribe and cut sessions.
extension FakeHostedRelay {
    struct Faults {
        /// Op case name → the codes its next calls answer, one per call.
        var failures: [String: [Relay_V1_ErrorCode]] = [:]
        /// HTTP statuses the next upgrades are refused with, one per dial.
        var dialRefusals: [Int] = []
        var crashed = false
        var pongs = true
        /// Zones whose next subscribe gets no answer.
        var silenced: Set<String> = []
    }

    /// The next `times` calls of `op` (the oneof case name: `save`, `createUpload`,
    /// `subscribe`, ...) answer `code` before anything else is checked, over HTTPS or a socket.
    public func failNext(_ op: String, with code: Relay_V1_ErrorCode, times: Int = 1) {
        locked { state.faults.failures[op, default: []].append(contentsOf: Array(repeating: code, count: times)) }
    }

    /// The next `times` upgrades answer HTTP `status` (401 makes the client log in again).
    public func refuseNextDial(status: Int, times: Int = 1) {
        locked { state.faults.dialRefusals.append(contentsOf: Array(repeating: status, count: times)) }
    }

    /// A rollout: requests already received have their answers queued (every op runs to the
    /// end before this can), then every socket closes with 1001 and no `GoingAway` frame,
    /// as Cloudflare's platform close does (R32 of the relay). State is kept.
    public func deploy() {
        locked {
            for socket in state.sockets { close(socket, code: Self.closeGoingAway) }
        }
    }

    /// Server-side displacement of the device's socket: `GoingAway`, then 1001.
    public func displace(deviceID: String) {
        locked {
            for socket in state.sockets where socket.deviceID == deviceID { goAway(socket) }
        }
    }

    /// The server dies: every socket is cut (no close frame, unread frames lost), dials and
    /// HTTPS requests fail as unreachable until `restart()`.
    public func crash() {
        locked {
            state.faults.crashed = true
            for socket in state.sockets { socket.cut() }
            state.sockets = []
        }
    }

    /// The server is back with the state it had.
    public func restart() {
        locked { state.faults.crashed = false }
    }

    /// Off: pings get no pong until the socket closes (the client's 10 s pong deadline).
    public func setPongs(_ on: Bool) {
        locked { state.faults.pongs = on }
    }

    var pongs: Bool {
        locked { state.faults.pongs }
    }

    /// The next subscribe that names `zone` gets no answer (the client's 10 s subscribe deadline).
    public func silenceSubscribe(zone: String) {
        _ = locked { state.faults.silenced.insert(zone) }
    }

    /// The device's sessions end now: HTTPS answers `UNAUTHENTICATED`, and each of its
    /// sockets gets `Control{SESSION_EXPIRED}` then close 4001 (Worker `ws.ts` `expire`).
    public func expireSessions(of deviceID: String) {
        locked {
            state.sessions = state.sessions.filter { $0.value.deviceID != deviceID }
            for socket in state.sockets where socket.deviceID == deviceID { expire(socket) }
        }
    }

    /// The code `failNext` queued for `op`, consumed (lock held).
    func takeFault(_ op: String) -> Relay_V1_ErrorCode? {
        guard var codes = state.faults.failures[op], !codes.isEmpty else { return nil }
        let code = codes.removeFirst()
        state.faults.failures[op] = codes
        return code
    }
}

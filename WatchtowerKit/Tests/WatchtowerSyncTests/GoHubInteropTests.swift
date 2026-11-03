import XCTest

/// The Kit phone against a live headless Go hub over the relay's local stand (Go hub phase 2, Task 12),
/// run by `make relay-interop RELAY=../relay KIT=1`. The script brings the stand and the hub up and
/// exports two variables; without them every test skips, so the ordinary Kit suite never needs a stand.
///
/// - `WT_RELAY_INTEROP_URL`: the stand's origin.
/// - `WT_HUB_INTEROP_DIR`: the handoff folder. `hub.json` (`mode` `live|test` — a Mac with the app runs
///   the phase-1 test mode, which has no relay-only rules —, `workbench_id`, `typed`, `ready`: the stub
///   `claude`'s input file and ready mark); `pair.url` (the v4 link to parse); the test writes the code
///   its phone shows to `pair.sas` (temp file + rename) and the script confirms it only when it equals
///   the hub's; `pair.result` (the pairing's last line, written after a linked phone got the typing and
///   start_sessions grants).
///
/// The bodies wait for `HostedRelayTransport` and the phone link flow (relay client spec Phase 3).
final class GoHubInteropTests: XCTestCase {
    /// The stand's origin and the handoff folder, or a skip when the script did not start the run.
    private func interopEnvironment() throws -> (relay: URL, dir: URL) {
        let env = ProcessInfo.processInfo.environment
        guard let origin = env["WT_RELAY_INTEROP_URL"], !origin.isEmpty,
              let dir = env["WT_HUB_INTEROP_DIR"], !dir.isEmpty,
              let relay = URL(string: origin)
        else {
            throw XCTSkip("needs WT_RELAY_INTEROP_URL and WT_HUB_INTEROP_DIR: run make relay-interop RELAY=../relay KIT=1")
        }
        return (relay, URL(fileURLWithPath: dir, isDirectory: true))
    }

    private func requirePhoneClient() throws -> Never {
        throw XCTSkip("needs HostedRelayTransport (relay client spec Phase 3)")
    }

    /// The Kit parses the relay-only v4 QR, says hello with its `relay_device_id`, shows the hub's SAS,
    /// vouches and promotes; its `device_grant.transports == ["relay"]`.
    func testKitPhoneLinksAHeadlessHub() throws {
        _ = try interopEnvironment()
        try requirePhoneClient()
    }

    /// Spec §13 E2E (3): every record kind the Go hub sealed opens on the phone.
    func testKitPhoneOpensEveryRecordKindTheGoHubSealed() throws {
        _ = try interopEnvironment()
        try requirePhoneClient()
    }

    /// Actions a1..a3, one a `session_input` to the stub session, come back `applied` in order.
    func testGoHubAppliesKitActionsInOrder() throws {
        _ = try interopEnvironment()
        try requirePhoneClient()
    }

    /// A recording sent to a headless hub ends `failed not_supported`.
    func testRecordingOnAHeadlessHubIsNotSupported() throws {
        _ = try interopEnvironment()
        try requirePhoneClient()
    }
}

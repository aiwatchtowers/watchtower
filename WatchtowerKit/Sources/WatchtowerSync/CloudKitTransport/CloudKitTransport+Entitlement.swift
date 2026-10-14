import Foundation
#if os(macOS)
import Security
#elseif targetEnvironment(simulator)
import MachO
#endif

extension CloudKitTransport {
    /// Whether the RUNNING PROCESS is code-signed with the given iCloud
    /// container. Public because it is the composition-time transport switch
    /// (Plan 6 Decision 1): `AppEnvironment.init()` probes this to pick
    /// CloudKitTransport (entitled) vs InMemory+DemoSeed (unsigned sim/CI),
    /// and `start()`/`availability()` probe it to degrade instead of crash —
    /// CloudKit raises an uncatchable ObjC exception when touched without
    /// the entitlement. That exception fires specifically when the container
    /// ID is absent from `com.apple.developer.icloud-container-identifiers`,
    /// so we check that list rather than the presence of `icloud-services`.
    ///
    /// Per platform:
    /// - macOS: read the code-sign entitlements of the running process.
    /// - iOS simulator: signing embeds entitlements as the main executable's
    ///   `__TEXT,__entitlements` Mach-O section; `CODE_SIGNING_ALLOWED=NO`
    ///   builds (CI, `make mobile-test`/`mobile-run`) have no section and
    ///   probe false — the sim stays on the demo path.
    /// - iOS device: always true — an unsigned build cannot install on a
    ///   device, and entitlements come from the provisioning profile.
    public static func entitlementPresent(containerID: String = WatchtowerCloud.containerID) -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        guard let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.developer.icloud-container-identifiers" as CFString,
            nil
        ) else { return false }
        guard let list = value as? [String] else { return false }
        return list.contains(containerID)
        #elseif targetEnvironment(simulator)
        guard let data = simulatorEntitlementsSection(),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let entitlements = plist as? [String: Any],
              let list = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String]
        else { return false }
        return list.contains(containerID)
        #else
        return true
        #endif
    }

    #if targetEnvironment(simulator)
    /// The main executable's `__TEXT,__entitlements` section (XML plist),
    /// present only when the simulator build was actually code-signed. Found
    /// by scanning loaded images for MH_EXECUTE rather than referencing
    /// `_mh_execute_header`, which does not link from a test bundle.
    private static func simulatorEntitlementsSection() -> Data? {
        for index in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(index),
                  header.pointee.filetype == UInt32(MH_EXECUTE),
                  // 64-bit magic before the mach_header_64 rebind — iOS 17
                  // sims are 64-bit-only, this makes the safety self-evident.
                  header.pointee.magic == MH_MAGIC_64 else { continue }
            var size: UInt = 0
            let bytes = header.withMemoryRebound(to: mach_header_64.self, capacity: 1) {
                getsectiondata($0, "__TEXT", "__entitlements", &size)
            }
            guard let bytes, size > 0 else { return nil }
            return Data(bytes: bytes, count: Int(size))
        }
        return nil
    }
    #endif
}

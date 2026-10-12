import Foundation
import Security
import XCTest
@testable import WatchtowerMobile

/// The device id (board #62): only a confirmed "no entry" mints a new id; a
/// locked Keychain (a push launch before the first unlock) mints nothing and
/// the boot waits for the unlock.
@MainActor
final class DeviceIDKeychainTests: XCTestCase {
    /// A scripted Keychain that counts its writes.
    private final class FakeKeychain {
        var read: DeviceIDKeychain.ReadResult
        var addStatus: OSStatus = errSecSuccess
        private(set) var added: [String] = []

        init(read: DeviceIDKeychain.ReadResult) {
            self.read = read
        }

        var access: DeviceIDKeychain.Access {
            DeviceIDKeychain.Access(
                read: { self.read },
                add: { id in
                    self.added.append(id)
                    return self.addStatus
                }
            )
        }
    }

    func testAStoredIDIsReturnedAndNothingIsWritten() throws {
        let keychain = FakeKeychain(read: .found("device-acme-1"))

        let id = try DeviceIDKeychain.deviceID(fallback: try makeDefaults(), access: keychain.access)

        XCTAssertEqual(id, "device-acme-1")
        XCTAssertTrue(keychain.added.isEmpty)
    }

    func testNoEntryMintsOneIDAndStoresIt() throws {
        let keychain = FakeKeychain(read: .notFound)
        let defaults = try makeDefaults()

        let id = try DeviceIDKeychain.deviceID(fallback: defaults, access: keychain.access)

        XCTAssertEqual(keychain.added, [id])
        XCTAssertNil(defaults.string(forKey: DeviceIDKeychain.fallbackKey), "the Keychain took it")
    }

    func testARefusedWriteKeepsTheNewIDInDefaultsAndReusesIt() throws {
        let keychain = FakeKeychain(read: .notFound)
        keychain.addStatus = errSecNotAvailable
        let defaults = try makeDefaults()

        let first = try DeviceIDKeychain.deviceID(fallback: defaults, access: keychain.access)
        let second = try DeviceIDKeychain.deviceID(fallback: defaults, access: keychain.access)

        XCTAssertEqual(defaults.string(forKey: DeviceIDKeychain.fallbackKey), first)
        XCTAssertEqual(second, first, "the kept id, not a second new one")
        XCTAssertEqual(keychain.added.count, 1)
    }

    func testALockedKeychainMintsNothingAndThrowsLocked() throws {
        let keychain = FakeKeychain(read: .failed(errSecInteractionNotAllowed))
        let defaults = try makeDefaults()

        XCTAssertThrowsError(try DeviceIDKeychain.deviceID(fallback: defaults, access: keychain.access)) { error in
            let unavailable = error as? DeviceIDKeychain.Unavailable
            XCTAssertEqual(unavailable?.isLocked, true)
        }
        XCTAssertTrue(keychain.added.isEmpty, "no new id while the stored one cannot be read")
        XCTAssertNil(defaults.string(forKey: DeviceIDKeychain.fallbackKey))
    }

    func testAnyOtherReadFailureMintsNothingEither() throws {
        let keychain = FakeKeychain(read: .failed(errSecDecode))

        XCTAssertThrowsError(try DeviceIDKeychain.deviceID(fallback: try makeDefaults(), access: keychain.access)) { error in
            XCTAssertEqual(error as? DeviceIDKeychain.Unavailable, DeviceIDKeychain.Unavailable(status: errSecDecode))
            XCTAssertEqual((error as? DeviceIDKeychain.Unavailable)?.isLocked, false)
        }
        XCTAssertTrue(keychain.added.isEmpty)
    }

    func testALockedKeychainAtBootWaitsForTheUnlockAndAnotherFailureShowsIt() {
        let locked = WatchtowerMobileApp.Boot.make(processEnvironment: [:]) {
            throw DeviceIDKeychain.Unavailable(status: errSecInteractionNotAllowed)
        }
        guard case .waitingForUnlock = locked else {
            return XCTFail("a locked Keychain waits for the unlock, got \(locked)")
        }

        let broken = WatchtowerMobileApp.Boot.make(processEnvironment: [:]) {
            throw DeviceIDKeychain.Unavailable(status: errSecDecode)
        }
        guard case let .failed(message) = broken else {
            return XCTFail("another Keychain failure is shown, got \(broken)")
        }
        XCTAssertTrue(message.contains("Keychain"))
    }
}

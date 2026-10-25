import CoreFoundation
import Foundation
import Testing
@testable import WatchtowerCore

/// The reader against a throwaway domain under a temp path: CFPreferences
/// writes `<path>.plist` there, never this Mac's real preferences.
@Suite("ManagedPolicyReader")
struct ManagedPolicyReaderTests {
    private func tempDomain() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("policytest-\(UUID().uuidString)").path
    }

    private func write(_ value: Any?, key: String, domain: String) {
        CFPreferencesSetAppValue(key as CFString, value as CFPropertyList?, domain as CFString)
        CFPreferencesAppSynchronize(domain as CFString)
    }

    @Test("an unforced value (defaults write) is never read")
    func unforcedIgnored() {
        let domain = tempDomain()
        write(["slack"] as CFArray, key: "AllowedSources", domain: domain)
        defer { write(nil, key: "AllowedSources", domain: domain) }
        #expect(ManagedPolicyReader.readForced(domain: domain).isEmpty)
    }

    @Test("forced values are read; a forced key with no value fails closed as NSNull")
    func forcedReadAndMissingFailsClosed() {
        let domain = tempDomain()
        write(["slack"] as CFArray, key: "AllowedSources", domain: domain)
        write(kCFBooleanFalse, key: "AllowAutomationShell", domain: domain)
        defer {
            write(nil, key: "AllowedSources", domain: domain)
            write(nil, key: "AllowAutomationShell", domain: domain)
        }
        let forced: Set<String> = ["AllowedSources", "AllowAutomationShell", "MobileSync"]
        let raw = ManagedPolicyReader.readForced(domain: domain) { key, _ in forced.contains(key) }
        #expect(Set(raw.keys) == forced)
        #expect(raw["MobileSync"] is NSNull)
        let p = ManagedPolicy.normalize(raw)
        #expect(p.allowedSources == ["slack"])
        #expect(p.allowAutomationShell == false)
        #expect(p.mobileSyncMode == "off", "a forced key without a value is the most restrictive")
    }

    @Test("under XCTest the app's reader reads nothing")
    func appReadEmptyUnderTests() {
        #expect(ManagedPolicyReader.appRead().isEmpty)
    }
}

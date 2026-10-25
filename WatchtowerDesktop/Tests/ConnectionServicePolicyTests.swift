import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// Every Settings → Connections service is either a policy source (#608,
/// `AllowedSources`) or named here as not one, so a new service is never
/// silently unchecked.
final class ConnectionServicePolicyTests: XCTestCase {
    func testEveryConnectionServiceIsMappedOrNotASource() {
        let notASource: Set<ConnectionService> = [.quickConnections]
        for service in ConnectionService.allCases {
            let source = PolicySourceMap.policySource(forAccountKind: service.rawValue)
            if notASource.contains(service) {
                XCTAssertNil(source, "\(service)")
            } else {
                XCTAssertNotNil(source, "\(service) maps to no AllowedSources name")
            }
        }
    }
}

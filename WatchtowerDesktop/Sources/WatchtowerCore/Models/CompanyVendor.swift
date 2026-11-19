import Foundation

/// A vendor block of the company bundle (company setup spec §1), in the
/// bundle's order. The raw values are Go's vendor names (`company list
/// --json`'s `vendors` keys).
package enum CompanyVendor: String, CaseIterable, Codable, Sendable {
    case slack, google, atlassian, linear, microsoft
}

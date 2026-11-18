import Foundation

/// One connected Linear workspace as `watchtower linear accounts --json`
/// prints it (`linearAccountJSON` in `cmd/linear.go`). Read from the CLI, not
/// the table: `auth` (how the account signs in) lives in the token file.
package struct LinearAccount: Decodable, Equatable, Identifiable, Sendable {
    package let id: Int64
    package let label: String
    package let orgName: String
    package let url: String
    /// "ok" | "error" | "revoked" | "removed" | "purged"
    package let status: String
    package let enabled: Bool
    package let error: String
    /// "oauth" | "api_key" | "" (no token file) | "error" (unreadable token file)
    package let auth: String
    /// The company bundle whose OAuth client this account signed in with
    /// (`company_slug`, migration 00198); "" = our shared client. Go writes
    /// it; the app only reads it.
    package let companySlug: String

    enum CodingKeys: String, CodingKey {
        case id, label, url, status, enabled, error, auth
        case orgName = "org_name"
        case companySlug = "company_slug"
    }

    package init(
        id: Int64,
        label: String = "",
        orgName: String = "",
        url: String = "",
        status: String = "ok",
        enabled: Bool = true,
        error: String = "",
        auth: String = "oauth",
        companySlug: String = ""
    ) {
        self.id = id
        self.label = label
        self.orgName = orgName
        self.url = url
        self.status = status
        self.enabled = enabled
        self.error = error
        self.auth = auth
        self.companySlug = companySlug
    }

    /// `company_slug` is optional so a CLI older than migration 00198 still
    /// decodes.
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        orgName = try c.decode(String.self, forKey: .orgName)
        url = try c.decode(String.self, forKey: .url)
        status = try c.decode(String.self, forKey: .status)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        error = try c.decode(String.self, forKey: .error)
        auth = try c.decode(String.self, forKey: .auth)
        companySlug = try c.decodeIfPresent(String.self, forKey: .companySlug) ?? ""
    }

    package var displayName: String {
        if !label.isEmpty { return label }
        if !orgName.isEmpty { return orgName }
        return "Linear workspace \(id)"
    }

    package var isOK: Bool { status == "ok" }
    package var isRemoved: Bool { status == "removed" }
    /// Its synced data was deleted (board #601); a Re-login revives it.
    package var isPurged: Bool { status == "purged" }
    package var usesAPIKey: Bool { auth == "api_key" }

    /// The auth line under the workspace name.
    package var authLabel: String {
        switch auth {
        case "oauth": "Signed in with Linear"
        case "api_key": "Personal API key"
        case "error": "Credential unreadable — sign in again"
        default: "Not signed in"
        }
    }

    /// The list Settings shows: every account the CLI prints except removed
    /// ones (their synced issues stay; `linear add` revives them).
    package static func decodeList(_ data: Data) throws -> [Self] {
        try JSONDecoder().decode([Self].self, from: data).filter { !$0.isRemoved }
    }
}

/// One Linear team of a workspace as `watchtower linear teams --json` prints it.
package struct LinearTeam: Decodable, Equatable, Identifiable, Sendable {
    package let key: String
    package let name: String
    package let selected: Bool

    package var id: String { key }

    package init(key: String, name: String, selected: Bool) {
        self.key = key
        self.name = name
        self.selected = selected
    }

    package static func decodeList(_ data: Data) throws -> [Self] {
        try JSONDecoder().decode([Self].self, from: data)
    }
}

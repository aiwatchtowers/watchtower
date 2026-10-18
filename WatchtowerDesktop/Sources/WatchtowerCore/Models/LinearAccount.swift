import Foundation

/// One connected Linear workspace as `watchtower linear accounts --json`
/// prints it (`linearAccountJSON` in `cmd/linear.go`). Read from the CLI, not
/// the table: `auth` (how the account signs in) lives in the token file.
package struct LinearAccount: Decodable, Equatable, Identifiable, Sendable {
    package let id: Int64
    package let label: String
    package let orgName: String
    package let url: String
    /// "ok" | "error" | "revoked" | "removed"
    package let status: String
    package let enabled: Bool
    package let error: String
    /// "oauth" | "api_key" | "" (no token file) | "error" (unreadable token file)
    package let auth: String

    enum CodingKeys: String, CodingKey {
        case id, label, url, status, enabled, error, auth
        case orgName = "org_name"
    }

    package init(
        id: Int64,
        label: String = "",
        orgName: String = "",
        url: String = "",
        status: String = "ok",
        enabled: Bool = true,
        error: String = "",
        auth: String = "oauth"
    ) {
        self.id = id
        self.label = label
        self.orgName = orgName
        self.url = url
        self.status = status
        self.enabled = enabled
        self.error = error
        self.auth = auth
    }

    package var displayName: String {
        if !label.isEmpty { return label }
        if !orgName.isEmpty { return orgName }
        return "Linear workspace \(id)"
    }

    package var isOK: Bool { status == "ok" }
    package var isRemoved: Bool { status == "removed" }
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

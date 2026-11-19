import Foundation

// Codable twins of the `watchtower company …` JSON the setup wizard reads
// and writes (Go `cmd/company_draft.go`, `cmd/company_check.go`,
// `cmd/company_publish.go`, `internal/company/draft.go`, `discover.go`).
// The draft goes to `company draft save` on stdin with its secrets (Go owns
// the 0600 file, A12); the Slack configuration token is never part of it.

/// The wizard draft (Go `company.Draft`). `checked` and `started_at` are
/// Go's to write: a save never sends them (`SaveDraft` keeps the stored ones).
package struct CompanyDraft: Codable, Equatable, Sendable {
    package var company = ""
    package var slug = ""
    package var services: [String] = []
    package var step = ""
    package var startedAt: Date?
    package var slack = Slack()
    package var google: Google?
    package var atlassian: Atlassian?
    package var linear: Linear?
    package var microsoft: Microsoft?
    package var denyHosts: [String] = []
    package var skipped: [String] = []
    package var microsoftWaiting = false

    package struct Slack: Codable, Equatable, Sendable {
        package var appID = ""
        package init(appID: String = "") { self.appID = appID }
        enum CodingKeys: String, CodingKey { case appID = "app_id" }
        package init(from decoder: Decoder) throws {
            appID = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .appID) ?? ""
        }
        package func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if !appID.isEmpty { try c.encode(appID, forKey: .appID) }
        }
    }

    package struct Google: Codable, Equatable, Sendable {
        package var clientID = ""
        package var clientSecret = ""
        package var domain = ""
        package init(clientID: String = "", clientSecret: String = "", domain: String = "") {
            self.clientID = clientID
            self.clientSecret = clientSecret
            self.domain = domain
        }
        enum CodingKeys: String, CodingKey { case clientID = "client_id", clientSecret = "client_secret", domain }
        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            clientID = try c.decodeIfPresent(String.self, forKey: .clientID) ?? ""
            clientSecret = try c.decodeIfPresent(String.self, forKey: .clientSecret) ?? ""
            domain = try c.decodeIfPresent(String.self, forKey: .domain) ?? ""
        }
    }

    package struct Atlassian: Codable, Equatable, Sendable {
        package var clientID = ""
        package var clientSecret = ""
        package var site = ""
        package var confluence = true
        package init(clientID: String = "", clientSecret: String = "", site: String = "", confluence: Bool = true) {
            self.clientID = clientID
            self.clientSecret = clientSecret
            self.site = site
            self.confluence = confluence
        }
        enum CodingKeys: String, CodingKey { case clientID = "client_id", clientSecret = "client_secret", site, confluence }
        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            clientID = try c.decodeIfPresent(String.self, forKey: .clientID) ?? ""
            clientSecret = try c.decodeIfPresent(String.self, forKey: .clientSecret) ?? ""
            site = try c.decodeIfPresent(String.self, forKey: .site) ?? ""
            confluence = try c.decodeIfPresent(Bool.self, forKey: .confluence) ?? false
        }
    }

    package struct Linear: Codable, Equatable, Sendable {
        package var clientID = ""
        package init(clientID: String = "") { self.clientID = clientID }
        enum CodingKeys: String, CodingKey { case clientID = "client_id" }
        package init(from decoder: Decoder) throws {
            clientID = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .clientID) ?? ""
        }
    }

    package struct Microsoft: Codable, Equatable, Sendable {
        package var clientID = ""
        package var tenantID = ""
        package init(clientID: String = "", tenantID: String = "") {
            self.clientID = clientID
            self.tenantID = tenantID
        }
        enum CodingKeys: String, CodingKey { case clientID = "client_id", tenantID = "tenant_id" }
        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            clientID = try c.decodeIfPresent(String.self, forKey: .clientID) ?? ""
            tenantID = try c.decodeIfPresent(String.self, forKey: .tenantID) ?? ""
        }
    }

    package init() {}

    enum CodingKeys: String, CodingKey {
        case company, slug, services, step, startedAt = "started_at", slack, google, atlassian, linear, microsoft
        case denyHosts = "deny_hosts", skipped, microsoftWaiting = "microsoft_waiting"
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        company = try c.decodeIfPresent(String.self, forKey: .company) ?? ""
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        services = try c.decodeIfPresent([String].self, forKey: .services) ?? []
        step = try c.decodeIfPresent(String.self, forKey: .step) ?? ""
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt).flatMap(Self.parseTime)
        slack = try c.decodeIfPresent(Slack.self, forKey: .slack) ?? Slack()
        google = try c.decodeIfPresent(Google.self, forKey: .google)
        atlassian = try c.decodeIfPresent(Atlassian.self, forKey: .atlassian)
        linear = try c.decodeIfPresent(Linear.self, forKey: .linear)
        microsoft = try c.decodeIfPresent(Microsoft.self, forKey: .microsoft)
        denyHosts = try c.decodeIfPresent([String].self, forKey: .denyHosts) ?? []
        skipped = try c.decodeIfPresent([String].self, forKey: .skipped) ?? []
        microsoftWaiting = try c.decodeIfPresent(Bool.self, forKey: .microsoftWaiting) ?? false
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(company, forKey: .company)
        if !slug.isEmpty { try c.encode(slug, forKey: .slug) }
        try c.encode(services, forKey: .services)
        try c.encode(step, forKey: .step)
        try c.encode(slack, forKey: .slack)
        try c.encodeIfPresent(google, forKey: .google)
        try c.encodeIfPresent(atlassian, forKey: .atlassian)
        try c.encodeIfPresent(linear, forKey: .linear)
        try c.encodeIfPresent(microsoft, forKey: .microsoft)
        if !denyHosts.isEmpty { try c.encode(denyHosts, forKey: .denyHosts) }
        if !skipped.isEmpty { try c.encode(skipped, forKey: .skipped) }
        if microsoftWaiting { try c.encode(true, forKey: .microsoftWaiting) }
    }

    /// Go's RFC 3339 time (fractional seconds or not); the zero time is none.
    private static func parseTime(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = plain.date(from: text) ?? fractional.date(from: text), date > Date(timeIntervalSince1970: 0) else {
            return nil
        }
        return date
    }
}

/// `company draft show --json`.
package struct CompanyDraftShow: Decodable, Equatable, Sendable {
    package var state: String
    package var draft: CompanyDraft?
    package var badFile: String
    package var checkedVendors: [String]

    enum CodingKeys: String, CodingKey { case state, draft, badFile = "bad_file", checkedVendors = "checked_vendors" }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(String.self, forKey: .state)
        draft = try c.decodeIfPresent(CompanyDraft.self, forKey: .draft)
        badFile = try c.decodeIfPresent(String.self, forKey: .badFile) ?? ""
        checkedVendors = try c.decodeIfPresent([String].self, forKey: .checkedVendors) ?? []
    }
}

/// A known company app (`company discover --json`, D19). Never a secret.
package struct CompanyCandidate: Decodable, Equatable, Sendable, Identifiable {
    package var vendor: String
    package var clientID: String
    package var appID: String
    package var tenantID: String
    package var label: String
    package var source: String
    package var sourceLabel: String
    package var hasSecret: Bool

    package var id: String { "\(vendor)|\(clientID)|\(appID)" }

    package init(
        vendor: String,
        clientID: String = "",
        appID: String = "",
        tenantID: String = "",
        label: String,
        source: String,
        sourceLabel: String,
        hasSecret: Bool = false
    ) {
        self.vendor = vendor
        self.clientID = clientID
        self.appID = appID
        self.tenantID = tenantID
        self.label = label
        self.source = source
        self.sourceLabel = sourceLabel
        self.hasSecret = hasSecret
    }

    enum CodingKeys: String, CodingKey {
        case vendor, clientID = "client_id", appID = "app_id", tenantID = "tenant_id", label, source
        case sourceLabel = "source_label", hasSecret = "has_secret"
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vendor = try c.decode(String.self, forKey: .vendor)
        clientID = try c.decodeIfPresent(String.self, forKey: .clientID) ?? ""
        appID = try c.decodeIfPresent(String.self, forKey: .appID) ?? ""
        tenantID = try c.decodeIfPresent(String.self, forKey: .tenantID) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        sourceLabel = try c.decodeIfPresent(String.self, forKey: .sourceLabel) ?? ""
        hasSecret = try c.decodeIfPresent(Bool.self, forKey: .hasSecret) ?? false
    }
}

struct CompanyDiscoverResult: Decodable {
    var candidates: [CompanyCandidate]?
}

/// `company check <vendor> --json`.
package struct CompanyCheckResult: Decodable, Equatable, Sendable {
    package var result: String
    package var slug = ""
    package var accountID: Int64 = 0
    package var email = ""
    package var domain = ""
    package var site = ""
    package var code = ""
    package var message = ""
    package var checked = false
    package var adminConsentURL = ""
    /// The check passed but marking the draft's step failed.
    package var draftError = ""
    /// Atlassian: the grant came back without the Confluence scopes
    /// (`"confluence": false`; Atlassian refused them, Jira alone connected).
    package var confluenceRefused = false
    /// `google add --client-id --json`: requested services the consent left
    /// unapproved ("calendar", "gmail").
    package var notGranted: [String] = []

    package init(result: String) { self.result = result }

    enum CodingKeys: String, CodingKey {
        case result, slug, accountID = "account_id", email, domain, site, code, message, checked
        case adminConsentURL = "admin_consent_url", confluence, draftError = "draft_error", notGranted = "not_granted"
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        result = try c.decode(String.self, forKey: .result)
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        accountID = try c.decodeIfPresent(Int64.self, forKey: .accountID) ?? 0
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        domain = try c.decodeIfPresent(String.self, forKey: .domain) ?? ""
        site = try c.decodeIfPresent(String.self, forKey: .site) ?? ""
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? ""
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        checked = try c.decodeIfPresent(Bool.self, forKey: .checked) ?? false
        adminConsentURL = try c.decodeIfPresent(String.self, forKey: .adminConsentURL) ?? ""
        draftError = try c.decodeIfPresent(String.self, forKey: .draftError) ?? ""
        confluenceRefused = try c.decodeIfPresent(Bool.self, forKey: .confluence) == false
        notGranted = try c.decodeIfPresent([String].self, forKey: .notGranted) ?? []
    }
}

/// The final line of `company publish --json`.
package struct CompanyPublishResult: Decodable, Equatable, Sendable {
    package var result: String
    package var slug = ""
    package var link = ""
    package var code = ""
    package var reason = ""
    package var message = ""
    package var draftError = ""

    package init(result: String) { self.result = result }

    enum CodingKeys: String, CodingKey { case result, slug, link, code, reason, message, draftError = "draft_error" }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        result = try c.decode(String.self, forKey: .result)
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        link = try c.decodeIfPresent(String.self, forKey: .link) ?? ""
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        draftError = try c.decodeIfPresent(String.self, forKey: .draftError) ?? ""
    }
}

/// A progress line of a JSON-lines verb (`{"step","state"}`).
struct CompanyStepLine: Decodable {
    var step: String
    var state: String
}

/// The fields of a downloaded Google OAuth client JSON (`installed` for a
/// Desktop app; `web` accepted).
package struct GoogleClientFile: Equatable, Sendable {
    package var clientID: String
    package var clientSecret: String
    package var projectID: String

    /// Nil when `data` is not a Google client JSON with an id and a secret.
    package init?(data: Data) {
        struct Wrapper: Decodable {
            struct Inner: Decodable {
                var client_id: String?
                var client_secret: String?
                var project_id: String?
            }

            var installed: Inner?
            var web: Inner?
        }
        guard let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data), let inner = wrapper.installed ?? wrapper.web,
              let id = inner.client_id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
              let secret = inner.client_secret?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty
        else { return nil }
        clientID = id
        clientSecret = secret
        projectID = inner.project_id ?? ""
    }
}

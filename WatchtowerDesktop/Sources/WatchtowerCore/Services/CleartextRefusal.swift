import Foundation

/// The Desktop side of Go's `internal/netsec` rule for accounts: a password
/// never crosses the network in cleartext (plain-http CalDAV, IMAP with
/// security "none"), a loopback host aside. The add sheets refuse inline;
/// an account the sync stopped carries `statusPrefix` on its row error.
package enum CleartextRefusal {
    /// Go `netsec.StatusPrefix`: starts the row error of a cleartext refusal.
    package static let statusPrefix = "transport: "

    package static let calendarStopped = "Stopped syncing: this server uses plain http, which would send your "
        + "password unencrypted. Remove the account and add it again with an https URL."
    package static let mailStopped = "Stopped syncing: this server uses no TLS, which would send your password "
        + "unencrypted. Remove the account and add it again with SSL or STARTTLS."

    package static let caldavCaption = "The password would be sent unencrypted: the server URL must use https. "
        + "Plain http is allowed only for localhost, 127.0.0.1 or ::1."
    package static let imapCaption = "\"None\" would send the password unencrypted: choose SSL or STARTTLS. "
        + "\"None\" is allowed only for localhost, 127.0.0.1 or ::1."

    /// The row is an account the sync stopped for a cleartext refusal.
    package static func stopped(status: String, error: String) -> Bool {
        status == "error" && error.hasPrefix(statusPrefix)
    }

    /// IMAP security "none" to `host` is refused (an empty host is not yet).
    package static func refusesNoTLS(host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !ExternalConnectionTransportRule.isLoopbackHost(trimmed)
    }

    /// A CalDAV server URL is refused: plain http to a remote host (or a URL
    /// that does not parse), as Go's `caldav.DialCalDAV`.
    package static func refusesCalDAV(url: String) -> Bool {
        ExternalConnectionTransportRule.sendsSecretInCleartext(url: url)
    }
}

/// An account's status in Settings → Accounts (design pass SET3): "ok" is
/// an 8 pt green dot and "OK", "error" a red exclamation mark and a red
/// "Error", "revoked" (a token the Mac lost; it needs reconnecting like an
/// error) the same mark and a red "Revoked", "live" (Slack with no synced
/// account and Live on, screens spec §2.3) a secondary "Live only" line, and
/// any other value (a newer Mac's) its raw text in secondary.
/// Role `.info`; never orange.
struct AccountStatusStyle: Equatable {
    enum Mark: Equatable {
        case dot
        case symbol(String)
        case textOnly
    }

    let mark: Mark
    let text: String
    let tone: PhoneTone
    let textTone: PhoneTone

    init(status: String) {
        switch status {
        case "ok":
            (mark, text, tone, textTone) = (.dot, "OK", .green, .secondary)
        case "error":
            (mark, text, tone, textTone) = (.symbol("exclamationmark.circle.fill"), "Error", .red, .red)
        case "revoked":
            (mark, text, tone, textTone) = (.symbol("exclamationmark.circle.fill"), "Revoked", .red, .red)
        case "live":
            (mark, text, tone, textTone) = (
                .textOnly, "Live only — sync needs your workspace's app", .secondary, .secondary
            )
        default:
            (mark, text, tone, textTone) = (.textOnly, status, .secondary, .secondary)
        }
    }

    var toneUses: [ToneUse] {
        [
            ToneUse(element: "settings account status mark", tone: tone, role: .info),
            ToneUse(element: "settings account status text", tone: textTone, role: .info)
        ]
    }
}

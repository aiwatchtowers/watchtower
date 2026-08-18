import Foundation
import WatchtowerCore

// MARK: - ImapFormSnapshot

/// Read-only projection of the IMAP form that the setup assistant is allowed
/// to see, injected into every chat turn.
///
/// PRIVACY BOUNDARY (load-bearing): this type deliberately has NO password
/// field, so the password VALUE cannot reach the assistant even by accident —
/// there is simply no slot to carry it. The assistant only ever learns whether
/// the password field is filled or empty via `hasPassword`. Do not add a
/// password property here.
struct ImapFormSnapshot {
    var host = ""
    var portText = ""
    var security = "ssl"
    var username = ""
    var folder = ""
    var label = ""
    /// Whether the (invisible-to-the-AI) password field is non-empty.
    var hasPassword = false
    /// Last "Test and Connect" failure, if any — safe to share: it is the
    /// error text the user already sees under the form.
    var lastConnectionError: String?
}

// MARK: - ImapSettingsPatch

/// Optional-fields patch parsed out of a ```watchtower-imap-settings``` block.
/// Every field is optional (partial blocks are allowed). There is NO password
/// field by design — see `ImapFormSnapshot`'s privacy boundary; if the model
/// ever emits a "password" key, the parser drops it on the floor.
struct ImapSettingsPatch: Equatable {
    var host: String?
    var port: Int?
    /// One of "ssl" / "starttls" / "none" — anything else is rejected by the parser.
    var security: String?
    var username: String?
    var folder: String?
    var label: String?

    var isEmpty: Bool {
        host == nil && port == nil && security == nil
            && username == nil && folder == nil && label == nil
    }
}

// MARK: - ImapSettingsParser

/// Extracts ```watchtower-imap-settings``` fenced JSON blocks from AI output
/// (same shape as `TargetActionParser`). All blocks are stripped from the
/// visible text; the LAST block wins as the applied patch. Tolerant by
/// contract: malformed/missing JSON is a no-op (nil patch), never a crash.
enum ImapSettingsParser {
    private static let pattern = "```watchtower-imap-settings\\s*\\n(.*?)\\n?```"
    private static let validSecurities: Set<String> = ["ssl", "starttls", "none"]

    static func parse(_ raw: String) -> (text: String, patch: ImapSettingsPatch?) {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.dotMatchesLineSeparators]
        ) else {
            return (raw, nil)
        }

        let full = raw as NSString
        let matches = regex.matches(in: raw, range: NSRange(location: 0, length: full.length))

        var patch: ImapSettingsPatch?
        if let last = matches.last, last.numberOfRanges >= 2 {
            patch = decode(full.substring(with: last.range(at: 1)))
        }

        let stripped = regex.stringByReplacingMatches(
            in: raw, range: NSRange(location: 0, length: full.length), withTemplate: ""
        )
        return (stripped.trimmingCharacters(in: .whitespacesAndNewlines), patch)
    }

    /// Decodes one block body. Unknown keys — including any "password" key the
    /// model might emit against instructions — are deliberately ignored, so a
    /// password can never flow through the patch into the form.
    private static func decode(_ json: String) -> ImapSettingsPatch? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return nil
        }
        var patch = ImapSettingsPatch()
        patch.host = obj["host"] as? String
        if let port = obj["port"] as? Int {
            patch.port = port
        } else if let text = obj["port"] as? String, let port = Int(text) {
            patch.port = port
        }
        if let sec = (obj["security"] as? String)?.lowercased(), validSecurities.contains(sec) {
            patch.security = sec
        }
        patch.username = obj["username"] as? String
        patch.folder = obj["folder"] as? String
        patch.label = obj["label"] as? String
        return patch.isEmpty ? nil : patch
    }
}

// MARK: - EmailSetupChatViewModel

/// Drives the embedded "Setup Assistant" chat next to the IMAP form in the
/// Add Email Account sheet. Same streaming skeleton as
/// `SituationChatViewModel`/`MeetingChatViewModel` (that duplication is the
/// house pattern), but EPHEMERAL: a setup wizard chat is throwaway, so nothing
/// is persisted to `chat_conversations`/`chat_messages` — only the CLI
/// `sessionID` is kept for turn-to-turn continuity within one sheet
/// presentation.
///
/// PRIVACY BOUNDARY: the assistant has NO access to the password field — not
/// read, not write, never in any prompt. Enforced structurally: `send()` takes
/// an `ImapFormSnapshot` (no password slot) and `ImapSettingsPatch` (no
/// password slot) is the only write-back channel.
@MainActor
@Observable
final class EmailSetupChatViewModel {
    var messages: [ChatMessage] = []
    var isStreaming = false
    var inputText = ""
    var errorMessage: String?

    /// Invoked on the main actor when a completed turn carries a settings
    /// block; the owning view writes the patch into its @State form fields.
    var onApplySettings: ((ImapSettingsPatch) -> Void)?

    private var sessionID: String?
    private let aiService: any AIServiceProtocol
    private var streamTask: Task<Void, Never>?

    init(aiService: (any AIServiceProtocol)? = nil) {
        self.aiService = aiService ?? WatchtowerAIService()
    }

    /// Local greeting shown when the panel opens — no AI call.
    static let greeting = "Hi! I can set up your mailbox for you. "
        + "Where is your email hosted — Gmail, Yahoo, iCloud, Yandex, a company address…? "
        + "Just tell me and I'll fill in the settings."

    func seedGreetingIfNeeded() {
        guard messages.isEmpty else { return }
        messages.append(ChatMessage(
            id: UUID(), role: .assistant, text: Self.greeting, timestamp: Date(), isStreaming: false
        ))
    }

    // MARK: - Sending

    func send(snapshot: ImapFormSnapshot) {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        inputText = ""
        sendUserMessage(text, snapshot: snapshot)
    }

    /// Feeds a failed "Test and Connect" error into the chat as a visible user
    /// turn so the assistant can explain it in plain words.
    func sendConnectionError(_ error: String, snapshot: ImapFormSnapshot) {
        guard !isStreaming else { return }
        sendUserMessage(
            "\"Test and Connect\" failed with this error:\n\(error)\n\nWhat should I do?",
            snapshot: snapshot
        )
    }

    private func sendUserMessage(_ text: String, snapshot: ImapFormSnapshot) {
        streamTask?.cancel()
        messages.append(ChatMessage(
            id: UUID(), role: .user, text: text, timestamp: Date(), isStreaming: false
        ))
        messages.append(ChatMessage(
            id: UUID(), role: .assistant, text: "", timestamp: Date(), isStreaming: true
        ))

        isStreaming = true
        let currentSessionID = sessionID

        streamTask = Task { [weak self] in
            await self?.executeStream(
                text: text, snapshot: snapshot, currentSessionID: currentSessionID
            )
        }
    }

    // MARK: - Stream execution

    private func executeStream(
        text: String,
        snapshot: ImapFormSnapshot,
        currentSessionID: String?
    ) async {
        let systemPrompt: String? = currentSessionID == nil ? Self.systemPrompt : nil
        // The form changes between turns (the user types, patches land), so
        // EVERY turn carries a fresh snapshot — which also keeps a resumed
        // session (system prompt dropped by CLI --resume) fully in context.
        let effectivePrompt = "\(Self.formStateBlock(snapshot))\n\n\(text)"

        var fullText = ""
        var streamFailed = false
        do {
            let stream = aiService.stream(
                prompt: effectivePrompt,
                systemPrompt: systemPrompt,
                sessionID: currentSessionID,
                dbPath: nil,
                model: nil  // nil = the provider's resolved strong-tier model
            )
            var sawTurnComplete = false
            for try await event in stream {
                switch event {
                case .text(let chunk):
                    if sawTurnComplete {
                        fullText = chunk
                        sawTurnComplete = false
                    } else {
                        fullText += chunk
                    }
                    updateLastMessage(fullText)
                case .turnComplete(let text):
                    fullText = text
                    sawTurnComplete = true
                    updateLastMessage(fullText)
                case .sessionID(let sid):
                    sessionID = sid
                case .done:
                    break
                }
            }
        } catch {
            streamFailed = true
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }

        // On a failed/cancelled stream, do NOT parse settings out of partial,
        // possibly-truncated output — a half-formed patch could misfill the form.
        if streamFailed {
            finishStream()
            return
        }

        let parsed = ImapSettingsParser.parse(fullText)
        let displayText = parsed.text.isEmpty && parsed.patch != nil
            ? "(filled in the settings on the left)"
            : parsed.text
        updateLastMessage(displayText)
        if let patch = parsed.patch {
            onApplySettings?(patch)
        }

        finishStream()
    }

    func cancelStream() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        if let idx = messages.indices.last, messages[idx].isStreaming {
            messages[idx].isStreaming = false
        }
    }

    // MARK: - State helpers

    private func updateLastMessage(_ text: String) {
        if let idx = messages.indices.last {
            messages[idx].text = text
        }
    }

    private func finishStream() {
        for idx in messages.indices where messages[idx].isStreaming {
            messages[idx].isStreaming = false
        }
        isStreaming = false
    }

    // MARK: - Prompt building

    /// Renders the form snapshot for the prompt. PRIVACY: the password is
    /// represented ONLY as "filled"/"empty" — the snapshot type cannot carry
    /// the value, so this function cannot leak it.
    nonisolated static func formStateBlock(_ snapshot: ImapFormSnapshot) -> String {
        func show(_ value: String) -> String {
            value.isEmpty ? "(empty)" : value
        }
        var lines = [
            "=== CURRENT FORM STATE ===",
            "Host: \(show(snapshot.host))",
            "Port: \(show(snapshot.portText))",
            "Security: \(show(snapshot.security))",
            "Username: \(show(snapshot.username))",
            "Folder: \(show(snapshot.folder))",
            "Label: \(show(snapshot.label))",
            "Password field: \(snapshot.hasPassword ? "filled" : "empty")"
        ]
        if let err = snapshot.lastConnectionError, !err.isEmpty {
            lines.append("Last connection error: \(err)")
        }
        return lines.joined(separator: "\n")
    }

    nonisolated static let systemPrompt = """
    You are a friendly email-setup assistant embedded in the Watchtower app, right next to an IMAP account form. \
    The user sees a form with fields: Host, Port, Security (SSL / STARTTLS / None), Username, Password, Folder, Label. \
    Your job is to fill the form FOR the user — they should never need to know what IMAP is.

    HOW TO BEHAVE
    - Reply in the same language the user writes in.
    - Ask ONE short question at a time. Start from: where is their mailbox hosted?
    - Keep every reply to a few sentences.

    KNOWN PROVIDERS (standard IMAP settings)
    - Gmail: imap.gmail.com, port 993, SSL. REQUIRES an app password (2-step verification must be enabled first): \
    https://myaccount.google.com/apppasswords
    - Outlook / Hotmail / Live: this app has a dedicated "Connect Outlook" button in this same sheet — \
    prefer that, it is easier than IMAP.
    - Yahoo: imap.mail.yahoo.com, 993, SSL. App password: https://login.yahoo.com/account/security
    - iCloud: imap.mail.me.com, 993, SSL. App-specific password: https://account.apple.com
    - Yandex: imap.yandex.com, 993, SSL. App password required, and IMAP must be enabled in the mailbox settings.
    - Mail.ru: imap.mail.ru, 993, SSL. App password required.
    - Fastmail: imap.fastmail.com, 993, SSL. App password required.
    - Zoho: imap.zoho.com, 993, SSL.
    - Corporate/unknown domain: suggest trying imap.<domain> or mail.<domain>, or asking IT; \
    if the mailbox is actually Microsoft 365, point at the "Connect Outlook" button instead.

    FILLING THE FORM
    When you state settings, ALWAYS also emit them in a fenced block so the app fills the form itself:
    ```watchtower-imap-settings
    {"host": "imap.gmail.com", "port": 993, "security": "ssl", "username": "user@gmail.com", "folder": "INBOX"}
    ```
    Partial keys are allowed. "security" must be one of: ssl, starttls, none. NEVER include a password key. \
    The block is hidden from the user, so also say in plain words what you filled in.

    PASSWORD RULES (hard boundary)
    - NEVER ask for, accept, or repeat the account password. The password field is intentionally invisible \
    to you; you only ever see whether it is filled or empty.
    - If the user pastes something that looks like a password into the chat, tell them to put it into the \
    Password field on the left instead, and DO NOT echo it back.

    FINISHING
    - Each user message carries the form's current state. When the form looks complete (password filled too), \
    tell the user to press "Test and Connect".
    - If you are given a connection error, explain the likely cause in plain words and what to do next. \
    AUTHENTICATIONFAILED with Gmail/Yahoo/iCloud usually means the normal account password was used \
    instead of an app password.
    """
}

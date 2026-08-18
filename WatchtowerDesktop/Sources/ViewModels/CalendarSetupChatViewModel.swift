import Foundation
import WatchtowerCore

// MARK: - CalendarFormSnapshot

/// Read-only projection of the calendar connect form that the setup assistant
/// is allowed to see, injected into every chat turn.
///
/// PRIVACY BOUNDARY (load-bearing): this type deliberately has NO password
/// field and NO feed-URL field — BOTH are credentials (the secret ICS address
/// grants read access to the whole calendar), so neither value can reach the
/// assistant even by accident: there is simply no slot to carry them. The
/// assistant only ever learns whether those fields are filled or empty via
/// `hasPassword` / `hasFeedURL`. Do not add a password or feed-URL property
/// here.
struct CalendarFormSnapshot {
    var caldavURL = ""
    var username = ""
    var label = ""
    /// Whether the (invisible-to-the-AI) CalDAV password field is non-empty.
    var hasPassword = false
    /// Whether the (invisible-to-the-AI) secret ICS feed URL field is non-empty.
    var hasFeedURL = false
    /// Last connect failure, if any — safe to share: it is the error text the
    /// user already sees under the form.
    var lastConnectionError: String?
}

// MARK: - CalendarSettingsPatch

/// Optional-fields patch parsed out of a ```watchtower-caldav-settings```
/// block. Every field is optional (partial blocks are allowed). There is NO
/// password field and NO feed-URL field by design — see
/// `CalendarFormSnapshot`'s privacy boundary; if the model ever emits a
/// "password"/"feed_url"/"ics_url" key, the parser drops it on the floor.
struct CalendarSettingsPatch: Equatable {
    var url: String?
    var username: String?

    var isEmpty: Bool { url == nil && username == nil }
}

// MARK: - CalendarSettingsParser

/// Extracts ```watchtower-caldav-settings``` fenced JSON blocks from AI output
/// (same shape as `ImapSettingsParser`). All blocks are stripped from the
/// visible text; the LAST block wins as the applied patch. Tolerant by
/// contract: malformed/missing JSON is a no-op (nil patch), never a crash.
enum CalendarSettingsParser {
    private static let pattern = "```watchtower-caldav-settings\\s*\\n(.*?)\\n?```"

    static func parse(_ raw: String) -> (text: String, patch: CalendarSettingsPatch?) {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.dotMatchesLineSeparators]
        ) else {
            return (raw, nil)
        }

        let full = raw as NSString
        let matches = regex.matches(in: raw, range: NSRange(location: 0, length: full.length))

        var patch: CalendarSettingsPatch?
        if let last = matches.last, last.numberOfRanges >= 2 {
            patch = decode(full.substring(with: last.range(at: 1)))
        }

        let stripped = regex.stringByReplacingMatches(
            in: raw, range: NSRange(location: 0, length: full.length), withTemplate: ""
        )
        return (stripped.trimmingCharacters(in: .whitespacesAndNewlines), patch)
    }

    /// Decodes one block body. Unknown keys — including any "password",
    /// "feed_url", or "ics_url" key the model might emit against instructions —
    /// are deliberately ignored, so a credential can never flow through the
    /// patch into the form.
    private static func decode(_ json: String) -> CalendarSettingsPatch? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return nil
        }
        var patch = CalendarSettingsPatch()
        patch.url = obj["url"] as? String
        patch.username = obj["username"] as? String
        return patch.isEmpty ? nil : patch
    }
}

// MARK: - CalendarSetupChatViewModel

/// Drives the embedded "Setup Assistant" chat next to the calendar connect
/// cards in the Add Calendar Account sheet. Deliberate copy of
/// `EmailSetupChatViewModel` (that duplication is the house pattern), and
/// EPHEMERAL like it: a setup wizard chat is throwaway, so nothing is
/// persisted to `chat_conversations`/`chat_messages` — only the CLI
/// `sessionID` is kept for turn-to-turn continuity within one sheet
/// presentation.
///
/// PRIVACY BOUNDARY: the assistant has NO access to the CalDAV password OR the
/// secret ICS feed URL — not read, not write, never in any prompt. Enforced
/// structurally: `send()` takes a `CalendarFormSnapshot` (no credential slots)
/// and `CalendarSettingsPatch` (url/username only) is the only write-back
/// channel.
@MainActor
@Observable
final class CalendarSetupChatViewModel {
    var messages: [ChatMessage] = []
    var isStreaming = false
    var inputText = ""
    var errorMessage: String?

    /// Invoked on the main actor when a completed turn carries a settings
    /// block; the owning view writes the patch into its @State form fields.
    var onApplySettings: ((CalendarSettingsPatch) -> Void)?

    private var sessionID: String?
    private let aiService: any AIServiceProtocol
    private var streamTask: Task<Void, Never>?

    init(aiService: (any AIServiceProtocol)? = nil) {
        self.aiService = aiService ?? WatchtowerAIService()
    }

    /// Local greeting shown when the panel opens — no AI call.
    static let greeting = "Hi! I can help you connect your calendar. "
        + "Which calendar do you use — Google, iCloud, Fastmail, Yandex, a company one…?"

    func seedGreetingIfNeeded() {
        guard messages.isEmpty else { return }
        messages.append(ChatMessage(
            id: UUID(), role: .assistant, text: Self.greeting, timestamp: Date(), isStreaming: false
        ))
    }

    // MARK: - Sending

    func send(snapshot: CalendarFormSnapshot) {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        inputText = ""
        sendUserMessage(text, snapshot: snapshot)
    }

    /// Feeds a failed connect error into the chat as a visible user turn so
    /// the assistant can explain it in plain words.
    func sendConnectionError(_ error: String, snapshot: CalendarFormSnapshot) {
        guard !isStreaming else { return }
        sendUserMessage(
            "Connecting failed with this error:\n\(error)\n\nWhat should I do?",
            snapshot: snapshot
        )
    }

    private func sendUserMessage(_ text: String, snapshot: CalendarFormSnapshot) {
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
        snapshot: CalendarFormSnapshot,
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

        let parsed = CalendarSettingsParser.parse(fullText)
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

    /// Renders the form snapshot for the prompt. PRIVACY: the CalDAV password
    /// and the secret ICS feed URL are represented ONLY as "filled"/"empty" —
    /// the snapshot type cannot carry either value, so this function cannot
    /// leak them.
    nonisolated static func formStateBlock(_ snapshot: CalendarFormSnapshot) -> String {
        func show(_ value: String) -> String {
            value.isEmpty ? "(empty)" : value
        }
        var lines = [
            "=== CURRENT FORM STATE ===",
            "CalDAV server URL: \(show(snapshot.caldavURL))",
            "Username: \(show(snapshot.username))",
            "Label: \(show(snapshot.label))",
            "Password field: \(snapshot.hasPassword ? "filled" : "empty")",
            "ICS feed URL field: \(snapshot.hasFeedURL ? "filled" : "empty")"
        ]
        if let err = snapshot.lastConnectionError, !err.isEmpty {
            lines.append("Last connection error: \(err)")
        }
        return lines.joined(separator: "\n")
    }

    nonisolated static let systemPrompt = """
    You are a friendly calendar-setup assistant embedded in the Watchtower app, right next to a calendar connect form. \
    The user sees two paths on the left: a CalDAV card (Server URL, Username, App password, Label) and an ICS card \
    (one field for a secret iCal/ICS feed link, plus Label). Your job is to figure out which path fits their calendar \
    and fill in what you can — they should never need to know what CalDAV is.

    HOW TO BEHAVE
    - Reply in the same language the user writes in.
    - Ask ONE short question at a time. Start from: which calendar do they use?
    - Keep every reply to a few sentences.

    KNOWN PROVIDERS
    - Google Calendar: the best path is the secret ICS link — no Google sign-in needed. Walk them through it: \
    open Google Calendar in a browser → Settings (gear icon) → click the specific calendar in the left list → \
    "Integrate calendar" → copy the "Secret address in iCal format". Warn them to treat that link like a password, \
    and to paste it into the ICS field on the left — you cannot see that field. Do NOT emit a settings block for \
    Google: there is nothing for you to fill; the secret link is user-pasted.
    - iCloud: CalDAV. Server URL https://caldav.icloud.com, username = their Apple ID email, and an app-specific \
    password created at https://account.apple.com (requires two-factor authentication). Emit a settings block \
    with url + username.
    - Fastmail: CalDAV. https://caldav.fastmail.com, app password required.
    - Yandex: CalDAV. https://caldav.yandex.ru, app password required.
    - Nextcloud: CalDAV. https://<server>/remote.php/dav — ask for their server address.
    - Outlook / Microsoft 365: the app's dedicated "Connect Outlook" flow covers mail; for the calendar, suggest \
    publishing an ICS link from Outlook's calendar settings and pasting it into the ICS field.
    - Corporate/unknown: suggest asking IT whether CalDAV is available or whether an ICS publish link exists.

    FILLING THE FORM
    When you state CalDAV settings, ALWAYS also emit them in a fenced block so the app fills the form itself:
    ```watchtower-caldav-settings
    {"url": "https://caldav.icloud.com", "username": "user@icloud.com"}
    ```
    Partial keys are allowed. The ONLY allowed keys are url and username. NEVER include any other key. \
    The block is hidden from the user, so also say in plain words what you filled in.

    CREDENTIAL RULES (hard boundary)
    - NEVER ask for, accept, or repeat the app password OR the secret ICS link value. Both fields are \
    intentionally invisible to you; you only ever see whether they are filled or empty.
    - If the user pastes a password or a secret link into the chat, tell them to put it into the matching \
    field on the left instead, and DO NOT echo it back.

    FINISHING
    - Each user message carries the form's current state. When the form looks complete (password or feed URL \
    filled too), tell the user to press the connect button.
    - If you are given a connection error, explain the likely cause in plain words and what to do next. \
    A 401 with iCloud/Fastmail/Yandex usually means the normal account password was used instead of an \
    app-specific password. A 404 on CalDAV usually means the server URL is wrong.
    """
}

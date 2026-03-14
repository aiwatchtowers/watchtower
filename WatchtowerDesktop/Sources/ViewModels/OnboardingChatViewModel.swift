import Foundation
import GRDB

/// ViewModel for the onboarding chat flow.
/// Manages: AI conversation, chat result parsing, team form state, profile generation.
@MainActor
@Observable
final class OnboardingChatViewModel {
    // MARK: - Chat State

    var messages: [ChatMessage] = []
    var isStreaming = false
    var inputText = ""
    var errorMessage: String?

    // MARK: - Parsed Profile Data (from chat)

    var role = ""
    var team = ""
    var painPoints: [String] = []
    var trackFocus: [String] = []

    // MARK: - Role Determination

    var hasAnsweredRoleQ1 = false
    var hasAnsweredRoleQ2 = false
    var hasAnsweredRoleQ3 = false
    var roleDetermination: RoleDetermination?

    var determinedRole: RoleLevel? {
        roleDetermination?.roleLevel
    }

    /// Check if Q3 (manage managers) should be shown
    var shouldShowRoleQ3: Bool {
        hasAnsweredRoleQ1 && hasAnsweredRoleQ2 &&
        (roleDetermination?.reportsToThem ?? false) &&
        (roleDetermination?.setStrategy ?? false)
    }

    // MARK: - Team Form State

    var reportIDs: [String] = []
    var managerID: String = ""
    var peerIDs: [String] = []
    var allUsers: [User] = []

    // MARK: - Private

    private var sessionID: String?
    private let claudeService: any ClaudeServiceProtocol
    private var dbManager: DatabaseManager?
    private var streamTask: Task<Void, Never>?
    private var chatCompleted = false

    init(claudeService: any ClaudeServiceProtocol, dbManager: DatabaseManager? = nil) {
        self.claudeService = claudeService
        self.dbManager = dbManager
        if dbManager != nil { loadUsers() }
    }

    /// Set database after initialization (e.g. when sync completes and DB becomes available).
    func setDatabase(_ db: DatabaseManager) {
        self.dbManager = db
        loadUsers()
    }

    // MARK: - Chat

    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }

        streamTask?.cancel()
        inputText = ""

        let userMsg = ChatMessage(id: UUID(), role: .user, text: text, timestamp: Date(), isStreaming: false)
        messages.append(userMsg)

        let assistantMsg = ChatMessage(id: UUID(), role: .assistant, text: "", timestamp: Date(), isStreaming: true)
        messages.append(assistantMsg)
        isStreaming = true

        let currentSessionID = sessionID

        streamTask = Task { [weak self] in
            guard let self else { return }

            let systemPrompt: String? = if currentSessionID == nil {
                Self.onboardingSystemPrompt
            } else {
                nil
            }

            do {
                let stream = claudeService.stream(
                    prompt: text,
                    systemPrompt: systemPrompt,
                    sessionID: currentSessionID,
                    dbPath: nil
                )
                var sawTurnComplete = false
                for try await event in stream {
                    switch event {
                    case .text(let chunk):
                        if let idx = self.messages.indices.last {
                            if sawTurnComplete {
                                self.messages[idx].text = chunk
                                sawTurnComplete = false
                            } else {
                                self.messages[idx].text += chunk
                            }
                        }
                    case .turnComplete(let fullText):
                        if let idx = self.messages.indices.last {
                            self.messages[idx].text = fullText
                        }
                        sawTurnComplete = true
                    case .sessionID(let sid):
                        self.sessionID = sid
                    case .done:
                        break
                    }
                }
            } catch {
                if !Task.isCancelled {
                    self.errorMessage = error.localizedDescription
                }
            }

            if let idx = self.messages.indices.last {
                self.messages[idx].isStreaming = false
            }
            self.isStreaming = false
        }
    }

    /// Finish the chat phase and parse results from the conversation.
    func finishChat() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        chatCompleted = true
        parseProfileFromChat()
    }

    /// Record role determination answer from UI questions.
    func recordRoleAnswer(reportsToThem: Bool? = nil, setStrategy: Bool? = nil, manageManagers: Bool? = nil, influenceType: String? = nil) {
        if let reportsToThem {
            roleDetermination = RoleDetermination(
                reportsToThem: reportsToThem,
                setStrategy: roleDetermination?.setStrategy ?? false,
                manageManagers: roleDetermination?.manageManagers,
                influenceType: roleDetermination?.influenceType
            )
            hasAnsweredRoleQ1 = true
        }

        if let setStrategy {
            roleDetermination = RoleDetermination(
                reportsToThem: roleDetermination?.reportsToThem ?? false,
                setStrategy: setStrategy,
                manageManagers: roleDetermination?.manageManagers,
                influenceType: roleDetermination?.influenceType
            )
            hasAnsweredRoleQ2 = true
        }

        if let manageManagers {
            roleDetermination = RoleDetermination(
                reportsToThem: roleDetermination?.reportsToThem ?? false,
                setStrategy: roleDetermination?.setStrategy ?? false,
                manageManagers: manageManagers,
                influenceType: roleDetermination?.influenceType
            )
            hasAnsweredRoleQ3 = true
        }

        if let influenceType {
            roleDetermination = RoleDetermination(
                reportsToThem: roleDetermination?.reportsToThem ?? false,
                setStrategy: roleDetermination?.setStrategy ?? false,
                manageManagers: roleDetermination?.manageManagers,
                influenceType: influenceType
            )
            hasAnsweredRoleQ2 = true
        }

        // Update role string from determined role
        if let determined = determinedRole {
            role = determined.rawValue
        }
    }

    // MARK: - Profile Generation

    /// Generate custom_prompt_context via LLM based on collected profile data.
    func generatePromptContext() async {
        let profileSummary = buildProfileSummary()
        let prompt = """
        Based on the following user profile, generate a concise context paragraph that will be \
        injected into AI prompts to personalize Slack workspace analysis.

        The context should describe who the user is, what they care about, and how to prioritize \
        information for them. Write in English, 3-5 sentences.

        PROFILE:
        Role: \(role)
        Team: \(team)
        Pain points: \(painPoints.joined(separator: ", "))
        Track focus: \(trackFocus.joined(separator: ", "))
        Reports: \(reportIDs.count) direct reports
        Has manager: \(managerID.isEmpty ? "no" : "yes")
        Peers: \(peerIDs.count) key peers

        Return ONLY the context paragraph, no explanation.
        """

        var contextText = ""
        do {
            for try await event in claudeService.stream(prompt: prompt, systemPrompt: nil, sessionID: nil, dbPath: nil) {
                switch event {
                case .text(let chunk): contextText += chunk
                case .turnComplete(let text): contextText = text
                case .sessionID, .done: break
                }
            }
        } catch {
            // Fallback: use the profile summary directly
            contextText = profileSummary
        }

        // Save profile
        let currentUserID = getCurrentUserID()
        guard !currentUserID.isEmpty else { return }
        guard let dbManager else {
            errorMessage = "Database not available"
            return
        }

        // Read existing profile to preserve onboardingDone state.
        let existingProfile: UserProfile? = try? await dbManager.dbPool.read { db in
            try ProfileQueries.fetchProfile(db, slackUserID: currentUserID)
        }

        let profile = UserProfile(
            slackUserID: currentUserID,
            role: role,
            team: team,
            reports: encodeJSON(reportIDs),
            peers: encodeJSON(peerIDs),
            manager: managerID,
            painPoints: encodeJSON(painPoints),
            trackFocus: encodeJSON(trackFocus),
            onboardingDone: existingProfile?.onboardingDone ?? false,
            customPromptContext: contextText.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        do {
            try await dbManager.dbPool.write { db in
                try ProfileQueries.upsertProfile(db, profile: profile)
            }
        } catch {
            errorMessage = "Failed to save profile: \(error.localizedDescription)"
        }
    }

    /// Mark onboarding as complete in the profile.
    func markOnboardingDone() async {
        let currentUserID = getCurrentUserID()
        guard !currentUserID.isEmpty else { return }
        guard let dbManager else { return }

        do {
            try await dbManager.dbPool.write { db in
                try db.execute(sql: """
                    UPDATE user_profile SET onboarding_done = 1,
                        updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                    WHERE slack_user_id = ?
                    """, arguments: [currentUserID])
            }
        } catch {
            errorMessage = "Failed to complete onboarding: \(error.localizedDescription)"
        }
    }

    // MARK: - Private Helpers

    private func loadUsers() {
        guard let dbManager else { allUsers = []; return }
        do {
            allUsers = try dbManager.dbPool.read { db in
                try UserQueries.fetchAll(db, activeOnly: true)
            }
        } catch {
            allUsers = []
        }
    }

    private func getCurrentUserID() -> String {
        guard let dbManager else { return "" }
        return (try? dbManager.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT current_user_id FROM workspace LIMIT 1")
        }) ?? ""
    }

    /// Parse the AI conversation to extract role, team, pain points, track focus.
    private func parseProfileFromChat() {
        let assistantMessages = messages
            .filter { $0.role == .assistant }
            .map { $0.text }
            .joined(separator: "\n")
        let userMessages = messages
            .filter { $0.role == .user }
            .map { $0.text }
            .joined(separator: "\n")

        // Simple heuristic extraction from user messages
        // The AI will have asked about role, pain points, etc. — the user's answers contain the data.
        // We keep it simple: store raw text, the LLM will generate proper context in generatePromptContext.

        // Try to detect role keywords (multi-word first, then abbreviations with word boundary check).
        let roleKeywords = ["engineering manager", "tech lead", "product manager",
                           "software engineer", "data scientist", "staff engineer",
                           "designer", "devops", "director", "principal",
                           "cto", "vp", "em", "tl", "pm", "swe", "ic"]
        let lowerUser = userMessages.lowercased()
        for keyword in roleKeywords {
            // For short keywords (≤3 chars), require word boundaries to avoid false positives.
            if keyword.count <= 3 {
                let pattern = "\\b\(NSRegularExpression.escapedPattern(for: keyword))\\b"
                if lowerUser.range(of: pattern, options: .regularExpression) != nil {
                    role = keyword.uppercased()
                    break
                }
            } else if lowerUser.contains(keyword) {
                role = keyword.capitalized
                break
            }
        }

        // Extract pain points from user messages using word-boundary matching
        let painPointKeywords = [
            "missing": "Missing important messages while AFK",
            "decisions": "Decisions getting lost in threads",
            "tracking": "Losing track of who owes what",
            "lose track": "Losing track of who owes what",
            "what team": "Can't tell what team is working on",
            "deadlines": "Deadlines discussed in chat get forgotten",
            "urgent": "Hard to tell what's urgent vs can wait",
            "prioritize": "Hard to tell what's urgent vs can wait",
        ]
        let lowerUserMessages = userMessages.lowercased()
        for (key, value) in painPointKeywords {
            if lowerUserMessages.contains(key) && !painPoints.contains(value) {
                painPoints.append(value)
            }
        }
    }

    private func buildProfileSummary() -> String {
        var parts: [String] = []
        if !role.isEmpty { parts.append("Role: \(role)") }
        if !team.isEmpty { parts.append("Team: \(team)") }
        if !painPoints.isEmpty { parts.append("Focus areas: \(painPoints.joined(separator: ", "))") }
        if !trackFocus.isEmpty { parts.append("Tracking: \(trackFocus.joined(separator: ", "))") }
        return parts.joined(separator: ". ")
    }

    private func encodeJSON(_ array: [String]) -> String {
        guard let data = try? JSONEncoder().encode(array),
              let str = String(data: data, encoding: .utf8) else { return "[]" }
        return str
    }

    // MARK: - System Prompt

    static let onboardingSystemPrompt = """
    You are Watchtower's onboarding assistant. Your goal is to learn about the user so \
    Watchtower can personalize their Slack monitoring experience.

    Have a brief, friendly conversation (3-5 exchanges) to learn:

    1. **Role & Team**: What's their position? (Engineering Manager, IC, Tech Lead, PM, etc.) \
    What team are they on?

    2. **Pain Points**: What problems do they face with Slack? Examples:
       - Missing important messages while away
       - Decisions getting lost in threads
       - Losing track of who owes what to whom
       - Can't tell what the team is busy with
       - Deadlines discussed in chat get forgotten
       - Hard to tell what's urgent vs what can wait

    3. **Track Focus**: What would they like Watchtower to track? (depends on their role)
       - For managers: team blockers, decisions, who's overloaded, deadlines
       - For ICs: code reviews, questions directed at them, architectural decisions
       - For tech leads: technical decisions, tech debt, team activity
       - For PMs: decisions, approvals, follow-ups, deadlines

    RULES:
    - Be concise — 2-3 sentences per message
    - Ask ONE question at a time, don't overwhelm
    - Adapt follow-up questions based on their answers
    - After gathering enough info (3-5 exchanges), end with a brief summary of what you learned \
    and say "Let's set up your team next!"
    - Match the user's language (if they write in Russian, respond in Russian)
    - Do NOT use any tools — this is a pure conversation
    """
}

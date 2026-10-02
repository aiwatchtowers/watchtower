import Foundation
import WatchtowerCore

/// What is left of the old onboarding interview: its LLM-written
/// `custom_prompt_context` save, kept only because three OWNER-01 guards
/// (`OnboardingChatViewModelOwnerTests`) still assert it while the owner
/// decides whether they move to `OnboardingProfileWriter` (variant A, see
/// docs/inventory/owner-identity.md). Nothing in the app uses it: onboarding
/// v2 has no chat. Delete it with those tests.
@MainActor
@Observable
final class OnboardingChatViewModel {
    var errorMessage: String?
    var role = ""
    var team = ""

    private let aiService: any AIServiceProtocol
    private let dbManager: DatabaseManager?

    init(aiService: any AIServiceProtocol, dbManager: DatabaseManager?) {
        self.aiService = aiService
        self.dbManager = dbManager
    }

    /// Generates `custom_prompt_context` from the role and team and saves it
    /// with them under the owner's profile key (no owner: parked on the
    /// no-owner key).
    func generatePromptContext() async {
        errorMessage = nil
        var contextText = ""
        do {
            contextText = try await AIStreamText.collect(aiService.stream(
                prompt: "Write a short profile context for this person. Role: \(role). Team: \(team).",
                systemPrompt: nil, sessionID: nil, dbPath: nil))
        } catch {
            NSLog("Onboarding: profile context generation failed: %@", String(describing: error))
        }
        await saveProfileWithContext(contextText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func saveProfileWithContext(_ contextText: String) async {
        guard let dbManager else {
            errorMessage = "Database not available"
            return
        }
        let role = self.role
        let team = self.team
        do {
            try await dbManager.dbPool.write { db in
                let owner = try OwnerQueries.resolve(db)
                let key = owner.isKnown ? owner.id : try ProfileQueries.noOwnerProfileKey(db)
                let existing = owner.isKnown
                    ? try ProfileQueries.fetchOwnerProfile(db, owner: owner)
                    : try ProfileQueries.fetchProfile(db, slackUserID: key)
                var profile = existing ?? UserProfile(slackUserID: key)
                profile.role = role
                profile.team = team
                if !contextText.isEmpty { profile.customPromptContext = contextText }
                if owner.isKnown {
                    try ProfileQueries.upsertOwnerProfile(db, owner: owner, profile: profile)
                } else {
                    try ProfileQueries.upsertProfile(db, profile: profile)
                }
            }
        } catch {
            errorMessage = "Failed to save profile: \(error.localizedDescription)"
        }
    }
}

import Foundation
import GRDB

package struct UserProfile: FetchableRecord, Identifiable {
    package let id: Int
    package let slackUserID: String
    package var role: String
    package var team: String
    package var responsibilities: String   // JSON array of strings
    package var reports: String            // JSON array of Slack user_ids
    package var peers: String              // JSON array of Slack user_ids
    package var manager: String            // Slack user_id
    package var starredChannels: String    // JSON array of channel_ids
    package var starredPeople: String      // JSON array of Slack user_ids
    package var painPoints: String         // JSON array from onboarding
    package var trackFocus: String         // JSON array of focus areas
    package var onboardingDone: Bool
    package var customPromptContext: String
    package let createdAt: String
    package let updatedAt: String

    package init(row: Row) {
        id = row["id"]
        slackUserID = row["slack_user_id"]
        role = row["role"] ?? ""
        team = row["team"] ?? ""
        responsibilities = row["responsibilities"] ?? "[]"
        reports = row["reports"] ?? "[]"
        peers = row["peers"] ?? "[]"
        manager = row["manager"] ?? ""
        starredChannels = row["starred_channels"] ?? "[]"
        starredPeople = row["starred_people"] ?? "[]"
        painPoints = row["pain_points"] ?? "[]"
        trackFocus = row["track_focus"] ?? "[]"
        onboardingDone = row["onboarding_done"] ?? false
        customPromptContext = row["custom_prompt_context"] ?? ""
        createdAt = row["created_at"] ?? ""
        updatedAt = row["updated_at"] ?? ""
    }

    package init(
        id: Int = 0,
        slackUserID: String,
        role: String = "",
        team: String = "",
        responsibilities: String = "[]",
        reports: String = "[]",
        peers: String = "[]",
        manager: String = "",
        starredChannels: String = "[]",
        starredPeople: String = "[]",
        painPoints: String = "[]",
        trackFocus: String = "[]",
        onboardingDone: Bool = false,
        customPromptContext: String = "",
        createdAt: String = "",
        updatedAt: String = ""
    ) {
        self.id = id
        self.slackUserID = slackUserID
        self.role = role
        self.team = team
        self.responsibilities = responsibilities
        self.reports = reports
        self.peers = peers
        self.manager = manager
        self.starredChannels = starredChannels
        self.starredPeople = starredPeople
        self.painPoints = painPoints
        self.trackFocus = trackFocus
        self.onboardingDone = onboardingDone
        self.customPromptContext = customPromptContext
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - JSON Helpers

    package var decodedReports: [String] {
        decodeJSONArray(reports)
    }

    package var decodedPeers: [String] {
        decodeJSONArray(peers)
    }

    package var decodedStarredChannels: [String] {
        decodeJSONArray(starredChannels)
    }

    package var decodedStarredPeople: [String] {
        decodeJSONArray(starredPeople)
    }

    package var decodedResponsibilities: [String] {
        decodeJSONArray(responsibilities)
    }

    package var decodedPainPoints: [String] {
        decodeJSONArray(painPoints)
    }

    package var decodedTrackFocus: [String] {
        decodeJSONArray(trackFocus)
    }

    private func decodeJSONArray(_ json: String) -> [String] {
        guard !json.isEmpty,
              let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}

extension UserProfile: Equatable {
    package static func == (lhs: UserProfile, rhs: UserProfile) -> Bool {
        lhs.slackUserID == rhs.slackUserID &&
        lhs.role == rhs.role &&
        lhs.team == rhs.team &&
        lhs.responsibilities == rhs.responsibilities &&
        lhs.reports == rhs.reports &&
        lhs.peers == rhs.peers &&
        lhs.manager == rhs.manager &&
        lhs.starredChannels == rhs.starredChannels &&
        lhs.starredPeople == rhs.starredPeople &&
        lhs.painPoints == rhs.painPoints &&
        lhs.trackFocus == rhs.trackFocus &&
        lhs.onboardingDone == rhs.onboardingDone &&
        lhs.customPromptContext == rhs.customPromptContext
    }
}

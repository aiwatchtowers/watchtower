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

// MARK: - Role Level Enum

package enum RoleLevel: String, Codable {
    case topManagement = "top_management"
    case directionOwner = "direction_owner"
    case middleManagement = "middle_management"
    case seniorIC = "senior_ic"
    case ic = "ic"

    package var displayName: String {
        switch self {
        case .topManagement: "Top Management"
        case .directionOwner: "Direction Owner"
        case .middleManagement: "Middle Management"
        case .seniorIC: "Senior IC"
        case .ic: "Individual Contributor"
        }
    }

    package var shortDescription: String {
        switch self {
        case .topManagement: "Sets organizational strategy"
        case .directionOwner: "Owns and executes strategy in an area"
        case .middleManagement: "Manages team and coordinates execution"
        case .seniorIC: "High technical influence, no direct reports"
        case .ic: "Solves tasks in their domain"
        }
    }
}

// Helper to determine role from onboarding answers
package struct RoleDetermination {
    package let reportsToThem: Bool      // Q1: "People report to you?"
    package let setStrategy: Bool        // Q2: "You set strategy?" (only if Q1=true)
    package let manageManagers: Bool     // Q3: "Do you manage other managers?" (only if Q1=true AND Q2=true)
    package let influenceType: String?   // Q2b: "expertise" or "tasks" (only if Q1=false)

    package init(reportsToThem: Bool, setStrategy: Bool, manageManagers: Bool, influenceType: String?) {
        self.reportsToThem = reportsToThem
        self.setStrategy = setStrategy
        self.manageManagers = manageManagers
        self.influenceType = influenceType
    }

    package var roleLevel: RoleLevel {
        if reportsToThem {
            if setStrategy {
                // Q1=true, Q2=true → need Q3
                return manageManagers ? .topManagement : .directionOwner
            } else {
                // Q1=true, Q2=false
                return .middleManagement
            }
        } else {
            // Q1=false → check Q2b influence type
            if let influenceType = influenceType {
                return influenceType == "expertise" ? .seniorIC : .ic
            }
            // Q2b not answered yet, default to IC
            return .ic
        }
    }

    package static func forIC() -> Self {
        Self(reportsToThem: false, setStrategy: false, manageManagers: false, influenceType: "tasks")
    }
}

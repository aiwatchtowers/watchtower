import Foundation
import WatchtowerCore

// MARK: - Meeting Prep Result (matches Go MeetingPrepResult)

struct TalkingPoint: Codable, Identifiable, Equatable {
    var id: String { text }
    let text: String
    let sourceType: String
    let sourceID: String
    let priority: String

    enum CodingKeys: String, CodingKey {
        case text, priority
        case sourceType = "source_type"
        case sourceID = "source_id"
    }
}

struct OpenItem: Codable, Identifiable, Equatable {
    var id: String { "\(type)-\(itemID)" }
    let text: String
    let type: String
    let itemID: String
    let personName: String
    let personID: String

    enum CodingKeys: String, CodingKey {
        case text, type
        case itemID = "id"
        case personName = "person_name"
        case personID = "person_id"
    }
}

struct PersonNote: Codable, Identifiable, Equatable {
    var id: String { userID }
    let userID: String
    let name: String
    let communicationTip: String
    let recentContext: String

    enum CodingKeys: String, CodingKey {
        case name
        case userID = "user_id"
        case communicationTip = "communication_tip"
        case recentContext = "recent_context"
    }
}

struct MeetingRecommendation: Codable, Identifiable, Equatable {
    var id: String { text }
    let text: String
    let category: String // agenda, format, participants, followup, preparation
    let priority: String // high, medium, low
}

struct MeetingPrepResult: Codable, Equatable {
    let eventID: String
    let title: String
    let startTime: String
    let talkingPoints: [TalkingPoint]
    let openItems: [OpenItem]
    let peopleNotes: [PersonNote]
    let suggestedPrep: [String]
    let recommendations: [MeetingRecommendation]?
    let contextGaps: [String]?

    enum CodingKeys: String, CodingKey {
        case title, recommendations
        case eventID = "event_id"
        case startTime = "start_time"
        case talkingPoints = "talking_points"
        case openItems = "open_items"
        case peopleNotes = "people_notes"
        case suggestedPrep = "suggested_prep"
        case contextGaps = "context_gaps"
    }
}

// MARK: - ViewModel

/// Prep state for ONE calendar event. Instances are handed out and kept by
/// `MeetingPrepCenter` on AppState, so a `meeting-prep` run (a strong-tier
/// CLI call taking tens of seconds) and its result survive navigating away
/// from Day Plan / Calendar and back.
@MainActor
@Observable
final class MeetingPrepViewModel {
    var result: MeetingPrepResult?
    var isLoading: Bool = false
    var error: String?
    var statusMessage: String = ""
    var isCached: Bool = false

    /// The in-flight (or last) run, kept so tests can await its completion.
    @ObservationIgnored private(set) var runTask: Task<Void, Never>?

    /// nil when the watchtower binary cannot be found.
    private let cli: (any CLIRunnerProtocol)?

    init(cliRunner: (any CLIRunnerProtocol)? = ProcessCLIRunner.makeDefault()) {
        self.cli = cliRunner
    }

    /// Generate meeting prep for a specific event. A no-op while a run is
    /// already in flight, so returning to a still-running prep (or a second
    /// click) never starts a parallel strong-tier call.
    /// - Parameters:
    ///   - eventID: The calendar event ID.
    ///   - userNotes: Optional agenda or context from the user.
    ///   - forceRefresh: If true, bypasses cache and regenerates.
    func generate(eventID: String, userNotes: String = "", forceRefresh: Bool = false) {
        var args = ["meeting-prep", eventID, "--json"]
        if forceRefresh {
            args.append("--force-refresh")
        }
        if !userNotes.isEmpty {
            args.append(contentsOf: ["--user-notes", userNotes])
        }
        start(
            args: args,
            initialStatus: "Gathering attendee context...",
            runningStatus: "Analyzing attendee activity..."
        ) { "Meeting prep failed (exit \($0))" }
    }

    /// Generate meeting prep for the next upcoming meeting.
    func generateNext(userNotes: String = "") {
        var args = ["meeting-prep", "next", "--json"]
        if !userNotes.isEmpty {
            args.append(contentsOf: ["--user-notes", userNotes])
        }
        start(
            args: args,
            initialStatus: "Finding next meeting...",
            runningStatus: "Analyzing attendees..."
        ) { _ in "No upcoming meetings found" }
    }

    /// Regenerate meeting prep, bypassing cache.
    func regenerate(eventID: String, userNotes: String = "") {
        generate(eventID: eventID, userNotes: userNotes, forceRefresh: true)
    }

    private func start(
        args: [String],
        initialStatus: String,
        runningStatus: String,
        emptyStderrError: @escaping (Int32) -> String
    ) {
        guard !isLoading else { return }
        guard let cli else {
            error = "Watchtower CLI not found"
            return
        }

        isLoading = true
        error = nil
        isCached = false
        statusMessage = initialStatus

        runTask = Task {
            statusMessage = runningStatus
            defer {
                isLoading = false
                statusMessage = ""
            }
            do {
                let data = try await cli.run(args: args)
                // ASCII whitespace only: the old Process wrapper trimmed stdout.
                if data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) {
                    error = emptyStderrError(0)
                } else {
                    parseCLIOutput(data)
                }
            } catch let CLIRunnerError.nonZeroExit(code, stderr) {
                error = stderr.isEmpty ? emptyStderrError(code) : String(stderr.prefix(300))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func parseCLIOutput(_ data: Data) {
        do {
            result = try JSONDecoder().decode(MeetingPrepResult.self, from: data)
        } catch {
            self.error = "Failed to parse meeting prep: \(error.localizedDescription)"
        }
    }
}

import Foundation

package struct MeetingExtractedTopic: Equatable {
    package var text: String
    package var priority: String

    package init(text: String, priority: String) {
        self.text = text
        self.priority = priority
    }
}

package struct MeetingTopicsExtractResult: Equatable {
    package var topics: [MeetingExtractedTopic]
    package var notes: String

    package init(topics: [MeetingExtractedTopic], notes: String) {
        self.topics = topics
        self.notes = notes
    }
}

/// Bridges the Desktop app to `watchtower meeting-prep extract-topics --json`.
package struct MeetingTopicsExtractService {
    package let runner: CLIRunnerProtocol

    package init(runner: CLIRunnerProtocol) {
        self.runner = runner
    }

    package func extract(text: String, eventID: String = "") async throws -> MeetingTopicsExtractResult {
        var args = ["meeting-prep", "extract-topics", "--json", "--text", text]
        if !eventID.isEmpty {
            args.append(contentsOf: ["--event-id", eventID])
        }
        let data = try await runner.run(args: args)
        let decoded = try JSONDecoder().decode(CLIExtractTopicsResponse.self, from: data)

        let topics = decoded.topics.map {
            MeetingExtractedTopic(text: $0.text, priority: $0.priority)
        }
        return MeetingTopicsExtractResult(topics: topics, notes: decoded.notes)
    }
}

private struct CLIExtractTopicsResponse: Decodable {
    let topics: [CLIExtractTopicItem]
    let notes: String
}

private struct CLIExtractTopicItem: Decodable {
    let text: String
    let priority: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        priority = (try c.decodeIfPresent(String.self, forKey: .priority)) ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case text
        case priority
    }
}

import Foundation

package enum SearchQueries {
    /// Sanitize user input for FTS5: wrap terms in double quotes, skip operators
    package static func sanitizeFTS5Query(_ input: String) -> String {
        let operators: Set<String> = ["AND", "OR", "NOT", "NEAR"]
        let words = input.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { !operators.contains($0.uppercased()) }
        return words
            .map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }
            .joined(separator: " ")
    }
}

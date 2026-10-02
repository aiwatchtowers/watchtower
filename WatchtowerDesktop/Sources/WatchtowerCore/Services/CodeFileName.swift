import Foundation

/// What the owner types to create or rename an entry of the FILES tree:
/// a name, or a relative path whose missing folders are created
/// (`internal/foo/bar.go`); `..` climbs out of the folder it is typed in, but
/// never above the workbench folder (by name — a symlinked folder inside it
/// is followed like any other).
package enum CodeFileName {
    package enum Problem: Error, Equatable, LocalizedError {
        case empty
        case absolute
        case badComponent(String)
        case outside

        package var errorDescription: String? {
            switch self {
            case .empty: "Type a name."
            case .absolute: "Use a name or a path inside the workbench, not one starting with /."
            case let .badComponent(part): "“\(part)” cannot be part of a name."
            case .outside: "That path leaves the workbench folder."
            }
        }
    }

    /// The new entry's path relative to the workbench folder: `input` under
    /// `directory` ("" = the folder itself). Surrounding spaces and a
    /// trailing slash are dropped; `.` is skipped, `..` climbs a level.
    package static func resolve(_ input: String, in directory: String) throws -> String {
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { throw Problem.empty }
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else { throw Problem.absolute }
        var parts = directory.split(separator: "/").map(String.init)
        for part in trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
            switch part {
            case "": throw Problem.badComponent("//")
            case ".": continue
            case "..":
                guard !parts.isEmpty else { throw Problem.outside }
                parts.removeLast()
            default:
                if part.contains("\0") { throw Problem.badComponent(part) }
                parts.append(part)
            }
        }
        guard !parts.isEmpty else { throw Problem.empty }
        return parts.joined(separator: "/")
    }
}

import Foundation

/// What the owner types to create or rename an entry of the FILES tree:
/// a name, or a relative path whose missing folders are created
/// (`internal/foo/bar.go`). Never leaves the folder it is typed in.
package enum CodeFileName {
    package enum Problem: Error, Equatable, LocalizedError {
        case empty
        case absolute
        case badComponent(String)

        package var errorDescription: String? {
            switch self {
            case .empty: "Type a name."
            case .absolute: "Use a name or a path inside the workbench, not one starting with /."
            case let .badComponent(part): "“\(part)” cannot be part of a name."
            }
        }
    }

    /// The new entry's path relative to the workbench folder: `input` under
    /// `directory` ("" = the folder itself). Surrounding spaces are trimmed;
    /// `.`, `..` and empty components are refused.
    package static func resolve(_ input: String, in directory: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Problem.empty }
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else { throw Problem.absolute }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if let bad = parts.first(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("\0") }) {
            throw Problem.badComponent(bad.isEmpty ? "//" : bad)
        }
        return directory.isEmpty ? parts.joined(separator: "/") : directory + "/" + parts.joined(separator: "/")
    }
}

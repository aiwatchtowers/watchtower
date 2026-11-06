import Darwin
import Foundation

/// lstat each prefix before access: never follow a custom executable or PATH
/// symlink into a privacy-protected folder. Ambiguous paths stay unverified.
package enum ProviderExecutableMetadata {
    package static func check(provider: String, override: String) throws -> ProviderConnection.Metadata {
        let home = NSHomeDirectory()
        if !override.isEmpty { return try check(path: override, home: home) }
        let known = [home + "/.local/bin", home + "/.claude/bin", "/usr/local/bin", "/opt/homebrew/bin", home + "/.volta/bin"]
        let paths = (Constants.resolvedEnvironmentIfReady()["PATH"] ?? "").split(separator: ":").map(String.init)
        var uncertain = false
        for directory in known + paths {
            switch try check(path: directory + "/" + provider, home: home) {
            case .notVerified: return .notVerified
            case .missingCLI: continue
            default: uncertain = true
            }
        }
        return uncertain ? .notVerified : .missingCLI
    }
    package static func check(path: String, home: String) throws -> ProviderConnection.Metadata {
        guard path.hasPrefix("/") else { return .notVerified }
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { if !components.isEmpty { components.removeLast() } } else { components.append(component) }
        }
        let normalized = "/" + components.joined(separator: "/")
        let blocked = ["Documents", "Desktop", "Downloads", "Music", "Movies", "Pictures", "Library/CloudStorage"]
        guard !blocked.contains(where: { normalized == home + "/" + $0 || normalized.hasPrefix(home + "/" + $0 + "/") }) else {
            return .notVerified
        }
        var current = ""
        for part in normalized.split(separator: "/") {
            current += "/" + part
            var info = stat()
            if lstat(current, &info) != 0 {
                if errno == ENOENT || errno == ENOTDIR { return .missingCLI }
                throw CocoaError(.fileReadNoPermission)
            }
            if info.st_mode & S_IFMT == S_IFLNK { return .notVerified }
        }
        return FileManager.default.isExecutableFile(atPath: normalized) ? .notVerified : .missingCLI
    }
}

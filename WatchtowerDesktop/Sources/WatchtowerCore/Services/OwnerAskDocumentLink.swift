import Foundation

/// Local review destinations go through the ask handler and folder confinement.
/// Absolute local URLs are made relative before the regular folder/symlink check.
package enum OwnerAskDocumentLink {
    package static func path(_ url: URL) -> String? {
        guard url.query == nil, url.fragment == nil, url.user == nil, url.password == nil,
              url.host?.isEmpty != false || url.host == "localhost" else { return nil }
        guard url.scheme == nil || url.scheme?.lowercased() == "file" else { return nil }
        let path = url.path
        guard !path.isEmpty, !path.split(separator: "/").contains("..") else { return nil }
        if url.scheme != nil, !path.hasPrefix("/") { return nil }
        return path
    }

    package static func relativePath(_ path: String, folder: String) -> String? {
        guard path.hasPrefix("/") else { return path }
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}

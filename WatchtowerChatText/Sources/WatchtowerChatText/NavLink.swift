import Foundation

/// In-app links the help answer uses to open a screen: `watchtower-nav://<screen>`.
public enum NavLink {
    public static let scheme = "watchtower-nav"

    public static func url(_ raw: String) -> URL {
        URL(string: "\(scheme)://\(raw)") ?? URL(fileURLWithPath: "/")
    }

    /// The screen raw value, only when the URL is a nav link to an allowed screen.
    public static func destination(from url: URL, allowed: Set<String>) -> String? {
        guard url.scheme == scheme, let host = url.host, allowed.contains(host) else { return nil }
        return host
    }
}

import Foundation

/// The app's own link schemes a rendered answer may carry, named once for every module that checks them.
public enum WatchtowerLinkScheme {
    /// A vault wiki-link tap out of rendered Markdown (Core `MemoryMarkdown.linkScheme`).
    public static let memory = "watchtower-memory"
}

import SwiftUI

/// The Workchat's IDE-style colours for the agent's text (spec 2026-11-24-workchat-polish §2, D3): a muted foreground
/// per kind of span, never a fill, a box or a weight.
public enum SyntaxTint {
    /// How strongly a span's colour shows over the text colour.
    public static let opacity = 0.7
    /// A target ref, `#2188`.
    public static let ref = Color.accentColor.opacity(opacity)
    /// A commit hash.
    public static let hash = Color.purple.opacity(opacity)
    /// A file path that resolves in a session folder.
    public static let path = Color.orange.opacity(opacity)
    /// A command in inline code (`make test`).
    public static let command = Color.green.opacity(opacity)
}

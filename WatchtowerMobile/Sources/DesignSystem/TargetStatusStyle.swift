import WatchtowerKit

/// A target status's glyph and tone, exactly the Mac's model table
/// (`WatchtowerCore/Models/Target.swift:280-300`, design pass spec §2.3).
/// The Mac's list view has no `in_review` colour; the phone follows the
/// model table (teal), the newer source. A status from a newer Mac draws a
/// secondary circle.
enum TargetStatusStyle {
    static func of(_ status: WorkbenchTargetStatus) -> (glyph: String, tone: PhoneTone) {
        switch status {
        case .todo: ("circle", .secondary)
        case .inProgress: ("circle.dotted.circle", .blue)
        case .inReview: ("eye.circle", .teal)
        case .blocked: ("exclamationmark.circle", .red)
        case .done: ("checkmark.circle.fill", .green)
        case .dismissed: ("xmark.circle", .gray)
        case .snoozed: ("moon.circle", .purple)
        default: ("circle", .secondary)
        }
    }
}

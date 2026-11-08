/// The merged share of a session's report, worded as the Mac words it
/// (`SessionReportPresentation`, board #986/#1008/#1017): "25 merged",
/// "25 merged (unchecked)" when the merge ref could not be checked, "merged
/// not checked" when none is known; nil when nothing is merged and the check
/// ran, or no task is in scope. One wording for the phone's session row and
/// its report screen, pinned by `merged_share_cases.json`, which the Mac's
/// own test reads too.
public enum MergedShareText {
    public static func text(merged: Int, total: Int, stale: Bool) -> String? {
        guard total > 0 else { return nil }
        switch (merged > 0, stale) {
        case (true, false): return "\(merged) merged"
        case (true, true): return "\(merged) merged (unchecked)"
        case (false, true): return "merged not checked"
        case (false, false): return nil
        }
    }
}

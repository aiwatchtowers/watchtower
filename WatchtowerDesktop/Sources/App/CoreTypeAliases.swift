import WatchtowerCore
import WatchtowerKit

// The desktop app imports both WatchtowerCore (desktop models) and
// WatchtowerKit (shared models + the phone's replica-side mirrors). Four type
// names exist in both modules; desktop code always means the Core one. The Kit
// mirrors stay reachable as `WatchtowerKit.X` where hub code needs them.
typealias MeetingTranscript = WatchtowerCore.MeetingTranscript
typealias Situation = WatchtowerCore.Situation
typealias DayPlan = WatchtowerCore.DayPlan
typealias DayPlanItem = WatchtowerCore.DayPlanItem

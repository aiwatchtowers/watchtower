import Foundation
import WatchtowerCore

/// An `ActionStripViewModel` built on `UserDefaults.standard` stores the
/// Idea finder's daily batch there on every read (`IdeaDailyBatch`). Test
/// classes that build one clear its keys in `tearDown`, so a stored
/// batch never leaks into another class or the developer's own defaults.
package enum IdeaBatchDefaults {
    package static func clearStandard() {
        UserDefaults.standard.removeObject(forKey: IdeaDailyBatch.dateKey)
        UserDefaults.standard.removeObject(forKey: IdeaDailyBatch.idsKey)
        UserDefaults.standard.removeObject(forKey: IdeaDailyBatch.dayIDsKey)
    }
}

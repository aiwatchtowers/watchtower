@testable import WatchtowerDesktop
import WatchtowerTestSupport

extension DatabaseManager {
    /// A fake tower that makes Go's screen writes on this test database
    /// (`FakeScreenTower.applying`).
    var fakeTower: FakeScreenTower { .applying(dbPool) }
}

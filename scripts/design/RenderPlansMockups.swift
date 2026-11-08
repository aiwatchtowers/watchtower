import AppKit
import SwiftUI
import DesignKit
import XCTest
struct DesignShot {
    let name: String
    let size: NSSize
    let make: @MainActor () -> AnyView
}
@main struct RenderPlans {
    @MainActor static func main() throws {
        if CommandLine.arguments[1] == "--test" {
            let suite = PlansMockupModelTests.defaultTestSuite
            suite.run()
            guard let result = suite.testRun, result.executionCount == 4, result.totalFailureCount == 0 else {
                fatalError("Plans mockup model tests failed")
            }
            return
        }
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        for shot in PlansShotFixtures.shots {
            for (suffix, name) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                let appearance = NSAppearance(named: name)!
                NSApp.appearance = appearance
                let data = try ViewRenderProbe(size: shot.size).png(shot.make(), appearance)
                try data.write(to: output.appendingPathComponent("\(shot.name)-\(suffix).png"))
                print("\(shot.name)-\(suffix).png")
            }
        }
    }
}

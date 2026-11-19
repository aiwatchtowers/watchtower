import AppKit
import DesignKit
import SwiftUI
import WatchtowerCore
import WatchtowerTestSupport
@testable import WatchtowerDesktop

/// The production **Use my own Google project** page (#1887 Task 26) over a
/// model driven to each `company-ownGoogle-*` state by a scripted `google
/// add`. Sample data only.
@MainActor
enum OwnGoogleLive {
    static let scenes = ["empty", "ready", "checking", "checkFailed", "done", "done-weekly"]

    private static let clientJSON = #"{"installed":{"client_id":"9876-home.apps.googleusercontent.com","#
        + #""client_secret":"sample-secret","project_id":"my-watchtower"}}"#
    private static let addArgs = ["google", "add"]

    static func page(_ name: String) -> AnyView {
        AnyView(OwnGoogleProjectPage(model: model(name)))
    }

    private static func model(_ name: String) -> OwnGoogleProjectModel {
        let cli = CompanyScriptedCLI()
        let model = OwnGoogleProjectModel(makeStreamer: { cli }, weeklyRelogin: name == "done-weekly")
        model.open()
        guard name != "empty" else { return model }
        model.drop(Data(clientJSON.utf8), fileName: "client_secret_9876-home.json")
        switch name {
        case "checking":
            cli.hold(addArgs)
            CompanyWizardLive.start({ await model.connect() }, until: { model.isRunning })
        case "checkFailed":
            cli.on(addArgs, [#"{"result":"rejected","code":"invalid_client"}"#])
            CompanyWizardLive.run { await model.connect() }
        case "done", "done-weekly":
            cli.on(addArgs, [#"{"result":"ok","account_id":4,"email":"bob@example.org"}"#])
            CompanyWizardLive.run { await model.connect() }
        default:
            break // ready
        }
        return model
    }
}

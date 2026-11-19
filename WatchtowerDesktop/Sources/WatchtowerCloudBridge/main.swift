import AppKit
import CloudBridgeCore
import Foundation

// WatchtowerCloudBridge.app (Go hub spec §6.2): the signed helper the daemon launches as
// `<bundle>/Contents/MacOS/WatchtowerCloudBridge --socket <hub dir>/bridge.sock`. Everything it does lives in
// CloudBridgeCore; this file only starts the app.
guard let arguments = BridgeArguments(CommandLine.arguments) else {
    FileHandle.standardError.write(Data("usage: WatchtowerCloudBridge --socket <absolute path of bridge.sock>\n".utf8))
    exit(64)
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = BridgeAppDelegate(arguments: arguments)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}

import AppKit
let session = CGSessionCopyCurrentDictionary() != nil
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let w = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
w.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
RunLoop.current.run(until: Date().addingTimeInterval(1))
let ev = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
print("cgsession=\(session) windowNumber=\(w.windowNumber) eventWindowMatches=\(ev?.window === w) isKey=\(w.isKeyWindow) keyWindowSet=\(app.keyWindow != nil)")

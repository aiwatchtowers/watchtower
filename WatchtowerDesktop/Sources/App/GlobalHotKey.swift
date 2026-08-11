import Foundation
import Carbon.HIToolbox

/// Global hotkey via Carbon RegisterEventHotKey — deliberately NOT an NSEvent
/// global monitor, which would require Accessibility permission (TCC prompt,
/// a P0 for this project). Carbon hotkeys need no permission.
@MainActor
final class GlobalHotKey {
    private static let signature: OSType = 0x51434150 // 'QCAP'

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let keyCode: UInt32
    private let modifiers: UInt32
    private let handler: () -> Void

    /// Default: Control+Option+D ("dictate").
    init(keyCode: UInt32 = UInt32(kVK_ANSI_D),
         modifiers: UInt32 = UInt32(controlKey | optionKey),
         handler: @escaping () -> Void) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.handler = handler
    }

    deinit {
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
    }

    /// Installs the event handler and registers the hotkey. A failure at
    /// either step (e.g. the combo is already taken by another app) is
    /// logged and left unregistered — the caller (the tray item) still works.
    func register() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let userData, let eventRef else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
                )
                // `Self` cannot be used here: a C function pointer cannot be
                // formed from a closure that captures dynamic Self type.
                // swiftlint:disable:next prefer_self_in_static_references
                guard status == noErr, hotKeyID.signature == GlobalHotKey.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().handler()
                return noErr
            },
            1, &eventType, selfPtr, &handlerRef
        )
        guard installStatus == noErr else {
            NSLog("GlobalHotKey: InstallEventHandler failed (status %d)", installStatus)
            return
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let registerStatus = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard registerStatus == noErr else {
            NSLog("GlobalHotKey: RegisterEventHotKey failed (status %d) — combo may be taken", registerStatus)
            if let handlerRef {
                RemoveEventHandler(handlerRef)
                self.handlerRef = nil
            }
            return
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }
}

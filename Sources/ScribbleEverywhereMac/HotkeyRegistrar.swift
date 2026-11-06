import AppKit
import Carbon.HIToolbox
import PalimpsestCore

/// Registers a global hotkey via Carbon's `RegisterEventHotKey`.
final class HotkeyRegistrar: PalimpsestCore.HotkeyRegistrar {
    var onHotkey: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var globalMonitor: Any?
    private var nextID: UInt32 = 1
    private let signature: OSType = 0x50414C49 // 'PALI'

    init() {
        installHandler()
    }

    deinit {
        unregister()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    @discardableResult
    func register(_ hotkey: Hotkey) -> Bool {
        unregister()

        let hotKeyID = EventHotKeyID(signature: signature, id: nextID)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )

        guard status == noErr, let reference else {
            Diagnostics.log("RegisterEventHotKey failed with status \(status) for \(hotkey.displayString)")
            return false
        }

        hotKeyRef = reference
        nextID += 1
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandler() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return OSStatus(eventNotHandledErr) }

            let registrar = Unmanaged<HotkeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
            guard hotKeyID.signature == registrar.signature else {
                return OSStatus(eventNotHandledErr)
            }
            registrar.onHotkey?()
            return noErr
        }

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        if status != noErr {
            Diagnostics.log("InstallEventHandler failed with status \(status)")
        }
    }
}

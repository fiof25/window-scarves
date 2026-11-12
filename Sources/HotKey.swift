import Carbon

/// A system-wide keyboard shortcut. Uses Carbon's hot key API, which needs no special permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var installed = false

    /// `keyCode` is a virtual key code (e.g. `kVK_ANSI_D`); `modifiers` uses Carbon masks (e.g. `controlKey`).
    init?(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        if !HotKey.installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                // Work out which of our shortcuts was pressed.
                var pressed = EventHotKeyID()
                let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                            EventParamType(typeEventHotKeyID), nil,
                                            MemoryLayout<EventHotKeyID>.size, nil, &pressed)
                guard err == noErr else { return err }
                let which = pressed.id
                DispatchQueue.main.async { HotKey.handlers[which]?() }
                return noErr
            }, 1, &spec, nil, nil)
            guard status == noErr else { return nil }
            HotKey.installed = true
        }
        id = HotKey.nextID
        HotKey.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x5343_4146), id: id)  // "SCAF"
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil }
        HotKey.handlers[id] = handler
    }

    deinit {
        HotKey.handlers[id] = nil
        if let ref { UnregisterEventHotKey(ref) }
    }
}

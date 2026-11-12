import Carbon

/// A system-wide keyboard shortcut. Uses Carbon's hot key API, which needs no special permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private static var handler: (() -> Void)?
    private static var installed = false

    /// `keyCode` is a virtual key code (e.g. `kVK_ANSI_D`); `modifiers` uses Carbon masks (e.g. `cmdKey`).
    init?(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        HotKey.handler = handler
        if !HotKey.installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.handler?() }
                return noErr
            }, 1, &spec, nil, nil)
            guard status == noErr else { return nil }
            HotKey.installed = true
        }
        let id = EventHotKeyID(signature: OSType(0x5343_4146), id: 1)  // "SCAF"
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }
}

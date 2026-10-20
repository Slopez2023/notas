import AppKit
import Carbon

enum CaptureShortcut: String, CaseIterable, Identifiable {
    case optionSpace, controlOptionSpace, off
    var id: String { rawValue }
    var label: String {
        switch self { case .optionSpace: "⌥Space"; case .controlOptionSpace: "⌃⌥Space"; case .off: "Off" }
    }
    func matches(_ event: NSEvent) -> Bool {
        guard self != .off, event.keyCode == UInt16(kVK_Space) else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        return flags == (self == .optionSpace ? [.option] : [.control, .option])
    }
    var modifiers: UInt32 {
        switch self { case .optionSpace: UInt32(optionKey); case .controlOptionSpace: UInt32(optionKey | controlKey); case .off: 0 }
    }
}

final class GlobalCaptureHotKey {
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    var action: (() -> Void)?

    func register(_ shortcut: CaptureShortcut) -> OSStatus {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        guard shortcut != .off else { return noErr }
        if eventHandler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                               MemoryLayout<EventHotKeyID>.size, nil, &identifier)
                guard status == noErr, identifier.signature == 0x4E544153, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
                let owner = Unmanaged<GlobalCaptureHotKey>.fromOpaque(context).takeUnretainedValue()
                owner.action?()
                return noErr
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
            guard status == noErr else { return status }
        }
        return RegisterEventHotKey(UInt32(kVK_Space), shortcut.modifiers, EventHotKeyID(signature: 0x4E544153, id: 1),
                                  GetApplicationEventTarget(), 0, &hotKey)
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}

import Carbon.HIToolbox
import Foundation

/// Global ⌥ Space via Carbon (no Accessibility permission needed for this part).
final class Hotkey {
    nonisolated(unsafe) static var handler: (() -> Void)?
    private var ref: EventHotKeyRef?

    @discardableResult
    func register(_ onPress: @escaping () -> Void) -> Bool {
        Hotkey.handler = onPress
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { Hotkey.handler?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4A525653), id: 1)
        return RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &ref) == noErr
    }
}

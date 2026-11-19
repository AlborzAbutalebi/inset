import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts (work while another app is focused, no Accessibility permission needed).
///   ⌃⌥1–4  switch layout    ⌃⌥R  record/stop    ⌃⌥P  pause    ⌃⌥V  preview    ⌃⌥S  swap
@MainActor
final class HotKeys {
    static let shared = HotKeys()
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var installed = false

    func install(_ model: AppModel) {
        guard !installed else { return }
        installed = true
        let mods = UInt32(controlKey | optionKey)
        register(kVK_ANSI_1, mods, 1) { model.setMode(.screen) }
        register(kVK_ANSI_2, mods, 2) { model.setMode(.camera) }
        register(kVK_ANSI_3, mods, 3) { model.setMode(.screenWithCamera) }
        register(kVK_ANSI_4, mods, 4) { model.setMode(.cameraWithScreen) }
        register(kVK_ANSI_R, mods, 5) { model.toggleRecording() }
        register(kVK_ANSI_P, mods, 6) { model.togglePause() }
        register(kVK_ANSI_V, mods, 7) { model.previewVisible.toggle() }
        register(kVK_ANSI_S, mods, 8) { model.swapMode() }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let key = id.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeys.shared.fire(key) } }
            return noErr
        }, 1, &spec, nil, nil)
    }

    private func register(_ key: Int, _ mods: UInt32, _ id: UInt32, _ action: @escaping () -> Void) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x494E_5354), id: id) // 'INST'
        if RegisterEventHotKey(UInt32(key), mods, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            refs.append(ref)
        }
        actions[id] = action
    }

    private func fire(_ id: UInt32) { actions[id]?() }
}

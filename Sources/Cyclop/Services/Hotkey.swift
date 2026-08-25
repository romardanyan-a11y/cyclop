import AppKit
import Carbon.HIToolbox

/// Global shortcut that opens the panel from the keyboard.
///
/// Carbon's `RegisterEventHotKey`, not an `NSEvent` global monitor. The monitor
/// would be the modern call and it is the wrong one here: monitoring key events
/// is gated behind Accessibility, so the app that asks for no permissions would
/// start asking for the one people trust least — and a shortcut is not worth
/// that. Registered hotkeys are delivered by the window server to whoever
/// claimed the combination, need no trust, and work while the app is inactive,
/// which an `.accessory` app always is.
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    /// What the panel is bound to. Every option is Space with different
    /// modifiers: the combinations people already reach for blindly are all
    /// Space-based, and one keycode keeps the setting a list rather than a
    /// recorder nobody asked for.
    enum Binding: Int, CaseIterable {
        case off = 0
        case optionSpace = 1
        case commandOptionSpace = 2
        case controlSpace = 3
        case shiftCommandSpace = 4

        /// Carbon modifier mask. `optionKey` and friends are the Carbon
        /// constants, unrelated to `NSEvent.ModifierFlags`.
        var carbonModifiers: UInt32 {
            switch self {
            case .off: return 0
            case .optionSpace: return UInt32(optionKey)
            case .commandOptionSpace: return UInt32(cmdKey | optionKey)
            case .controlSpace: return UInt32(controlKey)
            case .shiftCommandSpace: return UInt32(shiftKey | cmdKey)
            }
        }

        /// Shown in settings. Only "off" is a word; the rest are the symbols
        /// printed on the keys, and those read the same in every language.
        var title: String {
            switch self {
            case .off: return localized("Off")
            case .optionSpace: return "⌥Space"
            case .commandOptionSpace: return "⌘⌥Space"
            case .controlSpace: return "⌃Space"
            case .shiftCommandSpace: return "⇧⌘Space"
            }
        }
    }

    static let bindingKey = "panelHotkey"

    /// ⌘⌥Space by default: ⌥Space belongs to Alfred on a great many Macs and
    /// ⌃Space to the input-source switcher on the rest, and a default that
    /// silently loses to something already installed reads as a broken feature.
    static var currentBinding: Binding {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: bindingKey) != nil else { return .commandOptionSpace }
        return Binding(rawValue: defaults.integer(forKey: bindingKey)) ?? .commandOptionSpace
    }

    var onFire: (() -> Void)?

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x43_59_43_50 // 'CYCP'
    private static let identifier: UInt32 = 1
    private static let spaceKeyCode = UInt32(kVK_Space)

    private init() {}

    func install() {
        installHandlerIfNeeded()
        apply()
        // The setting lives in the panel's own Settings tab, so the change
        // arrives while the app is running and has to take effect there and
        // then. Cheap to re-register: unregistering and claiming again is two
        // calls, and nothing else in this app writes defaults often enough for
        // the notification to be a load.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
    }

    /// Claims the current binding, releasing whatever was held before.
    func apply() {
        unregister()
        let binding = Self.currentBinding
        guard binding != .off else { return }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: Self.identifier)
        let status = RegisterEventHotKey(
            Self.spaceKeyCode,
            binding.carbonModifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        // A combination already claimed by another app comes back as an error
        // rather than a silent no-op. Nothing is shown: the user is one menu
        // away from picking another, and a dialog from a menu bar app that
        // never opened a window is worse than a shortcut that does nothing.
        guard status == noErr else { return }
        hotKey = ref
    }

    func teardown() {
        unregister()
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }

    fileprivate func fire() {
        onFire?()
    }

    private func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), hotkeyEventHandler, 1, &spec, nil, &handler)
    }
}

/// C callback: no context to capture, so it goes through the shared instance.
private let hotkeyEventHandler: EventHandlerUPP = { _, event, _ in
    guard let event else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &id
    )
    guard status == noErr, id.signature == 0x43_59_43_50 else {
        return OSStatus(eventNotHandledErr)
    }
    DispatchQueue.main.async {
        MainActor.assumeIsolated { HotkeyCenter.shared.fire() }
    }
    return noErr
}

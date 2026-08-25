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
final class HotkeyCenter: ObservableObject {
    static let shared = HotkeyCenter()

    /// What the panel is bound to.
    ///
    /// Every option is Space with different modifiers, and every one of them is
    /// free of a macOS default. That is the whole list's reason for being what
    /// it is: ⌘Space is Spotlight, ⌘⌥Space opens the Finder search window,
    /// ⌃Space and ⌃⌥Space switch input sources. All four are registered by the
    /// system before any app runs, and the system wins — an app that offers one
    /// of them offers a shortcut that silently does nothing.
    enum Binding: Int, CaseIterable {
        case off = 0
        case optionSpace = 1
        case shiftCommandSpace = 2
        case optionShiftSpace = 3
        case controlOptionCommandSpace = 4

        /// Carbon modifier mask. `optionKey` and friends are the Carbon
        /// constants, unrelated to `NSEvent.ModifierFlags`.
        var carbonModifiers: UInt32 {
            switch self {
            case .off: return 0
            case .optionSpace: return UInt32(optionKey)
            case .shiftCommandSpace: return UInt32(shiftKey | cmdKey)
            case .optionShiftSpace: return UInt32(optionKey | shiftKey)
            case .controlOptionCommandSpace: return UInt32(controlKey | optionKey | cmdKey)
            }
        }

        /// Shown in settings. Only "off" is a word; the rest are the symbols
        /// printed on the keys, and those read the same in every language.
        var title: String {
            switch self {
            case .off: return localized("Off")
            case .optionSpace: return "⌥Space"
            case .shiftCommandSpace: return "⇧⌘Space"
            case .optionShiftSpace: return "⌥⇧Space"
            case .controlOptionCommandSpace: return "⌃⌥⌘Space"
            }
        }
    }

    static let bindingKey = "panelHotkey"

    static var currentBinding: Binding {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: bindingKey) != nil else { return .optionSpace }
        return Binding(rawValue: defaults.integer(forKey: bindingKey)) ?? .optionSpace
    }

    /// Whether the current binding is actually held.
    ///
    /// Published because the honest answer is sometimes no, and the only place
    /// that can say so is the settings row where the combination was picked.
    /// The first version of this swallowed the refusal: `RegisterEventHotKey`
    /// returned an error, the code returned early, and the shortcut looked
    /// identical to one that was working — which is the worst way for anything
    /// to fail, and it cost an afternoon to notice.
    @Published private(set) var isClaimed = true

    var onFire: (() -> Void)?

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var applied: Binding?
    private static let signature: OSType = 0x43_59_43_50 // 'CYCP'
    private static let identifier: UInt32 = 1
    private static let spaceKeyCode = UInt32(kVK_Space)

    private init() {}

    func install() {
        installHandlerIfNeeded()
        apply()
        // The setting lives in the panel's own Settings tab, so the change
        // arrives while the app is running and has to take effect there and
        // then.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyIfChanged() }
        }
    }

    /// Re-registering costs two trap calls, but `didChangeNotification` fires
    /// for every default this app writes — the shelf, the clipboard, the tab —
    /// and dropping the hotkey for an instant on each of those is a shortcut
    /// that misses keystrokes for reasons the user will never connect to
    /// copying a file.
    private func applyIfChanged() {
        guard Self.currentBinding != applied else { return }
        apply()
    }

    /// Claims the current binding, releasing whatever was held before.
    func apply() {
        unregister()
        let binding = Self.currentBinding
        applied = binding
        guard binding != .off else {
            isClaimed = true
            return
        }
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
        // A combination already claimed — by macOS itself or by another app —
        // comes back as an error rather than a silent no-op. It is reported,
        // not hidden: see `isClaimed`.
        isClaimed = status == noErr
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

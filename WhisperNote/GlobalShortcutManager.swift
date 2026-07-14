import AppKit
import Carbon
import Foundation

struct GlobalShortcut: Codable, Equatable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let suggested = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_R),
        modifiers: UInt32(cmdKey | optionKey)
    )

    var displayName: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        result += Self.keyName(keyCode)
        return result
    }

    func validate() throws {
        let supported = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        let primary = UInt32(cmdKey | optionKey | controlKey)
        guard keyCode <= 127,
              modifiers & ~supported == 0,
              modifiers.nonzeroBitCount >= 2,
              modifiers & primary != 0 else {
            throw GlobalShortcutError.invalidCombination
        }
        let reserved: Set<GlobalShortcut> = [
            GlobalShortcut(keyCode: UInt32(kVK_Escape), modifiers: UInt32(cmdKey | optionKey)),
            GlobalShortcut(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey | controlKey)),
            GlobalShortcut(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey | shiftKey)),
            GlobalShortcut(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey | optionKey)),
            GlobalShortcut(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey | optionKey)),
            GlobalShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | optionKey)),
            GlobalShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | controlKey)),
            GlobalShortcut(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | shiftKey)),
            GlobalShortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey)),
            GlobalShortcut(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(cmdKey | shiftKey))
        ]
        guard !reserved.contains(self) else {
            throw GlobalShortcutError.reservedCombination
        }
    }

    private static func keyName(_ code: UInt32) -> String {
        let names: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_Space): "Space", UInt32(kVK_Tab): "Tab"
        ]
        return names[code] ?? "Key \(code)"
    }
}

enum GlobalShortcutError: LocalizedError, Equatable {
    case invalidCombination
    case reservedCombination
    case registrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidCombination: return "Choose a key with at least two modifiers, including Command, Option, or Control."
        case .reservedCombination: return "That shortcut is reserved by macOS or WhisperNote."
        case .registrationFailed(let status):
            return status == eventHotKeyExistsErr
                ? "That shortcut is already used by another app."
                : "The global shortcut couldn't be registered (\(status))."
        }
    }
}

@MainActor
protocol GlobalHotKeyRegistering: AnyObject {
    func register(_ shortcut: GlobalShortcut, action: @escaping @Sendable () -> Void) throws
    func unregister()
}

@MainActor
final class CarbonGlobalHotKeyRegistrar: GlobalHotKeyRegistering {
    private static let signature: OSType = 0x574E4F54 // WNOT
    private static let identifier: UInt32 = 1
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (@Sendable () -> Void)?

    func register(_ shortcut: GlobalShortcut, action: @escaping @Sendable () -> Void) throws {
        unregister()
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let result = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard result == noErr,
                  hotKeyID.signature == CarbonGlobalHotKeyRegistrar.signature,
                  hotKeyID.id == CarbonGlobalHotKeyRegistrar.identifier else { return OSStatus(eventNotHandledErr) }
            Unmanaged<CarbonGlobalHotKeyRegistrar>.fromOpaque(userData).takeUnretainedValue().action?()
            return noErr
        }, 1, &eventType, userData, &handler)
        guard status == noErr else { throw GlobalShortcutError.registrationFailed(status) }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.identifier)
        let registerStatus = RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers, hotKeyID,
            GetApplicationEventTarget(), OptionBits(0), &hotKey
        )
        guard registerStatus == noErr else {
            unregister()
            throw GlobalShortcutError.registrationFailed(registerStatus)
        }
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        action = nil
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

@MainActor
final class GlobalShortcutManager: ObservableObject {
    static let enabledKey = "globalRecordingShortcutEnabled"
    static let bindingKey = "globalRecordingShortcutBinding"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var shortcut: GlobalShortcut
    @Published private(set) var errorMessage: String?

    private let defaults: UserDefaults
    private let registrar: any GlobalHotKeyRegistering
    private var action: (@MainActor () -> Void)?

    init(defaults: UserDefaults = .standard, registrar: (any GlobalHotKeyRegistering)? = nil) {
        self.defaults = defaults
        self.registrar = registrar ?? CarbonGlobalHotKeyRegistrar()
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        if let data = defaults.data(forKey: Self.bindingKey),
           let saved = try? JSONDecoder().decode(GlobalShortcut.self, from: data),
           (try? saved.validate()) != nil {
            self.shortcut = saved
        } else {
            self.shortcut = .suggested
        }
    }

    func setAction(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    func activatePersistedSetting() {
        guard isEnabled else { registrar.unregister(); return }
        do { try register(shortcut); errorMessage = nil }
        catch { isEnabled = false; defaults.set(false, forKey: Self.enabledKey); errorMessage = error.localizedDescription }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if !enabled {
            registrar.unregister()
            isEnabled = false
            defaults.set(false, forKey: Self.enabledKey)
            errorMessage = nil
            return
        }
        do {
            try shortcut.validate()
            try register(shortcut)
            isEnabled = true
            defaults.set(true, forKey: Self.enabledKey)
            errorMessage = nil
        } catch {
            isEnabled = false
            defaults.set(false, forKey: Self.enabledKey)
            errorMessage = error.localizedDescription
        }
    }

    func updateShortcut(_ proposed: GlobalShortcut) {
        do {
            try proposed.validate()
            let previous = shortcut
            if isEnabled {
                registrar.unregister()
                do { try register(proposed) }
                catch let proposedError {
                    do { try register(previous) }
                    catch {
                        isEnabled = false
                        defaults.set(false, forKey: Self.enabledKey)
                        throw error
                    }
                    throw proposedError
                }
            }
            shortcut = proposed
            persist(proposed)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restoreSuggested() { updateShortcut(.suggested) }

    private func register(_ shortcut: GlobalShortcut) throws {
        try registrar.register(shortcut) { [weak self] in
            Task { @MainActor in self?.action?() }
        }
    }

    private func persist(_ shortcut: GlobalShortcut) {
        if let data = try? JSONEncoder().encode(shortcut) { defaults.set(data, forKey: Self.bindingKey) }
    }
}

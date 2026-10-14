import AppKit
import Carbon

struct LaunchShortcut: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt
    let character: String
    static let defaultShortcut = LaunchShortcut(keyCode: UInt32(kVK_ANSI_E), modifiers: NSEvent.ModifierFlags.command.rawValue, character: "E")
    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }
    var isValid: Bool {
        let allowed: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        return keyCode < 128 && character.count == 1 && character.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
            && !flags.intersection([.command, .control, .option]).isEmpty && flags.subtracting(allowed).isEmpty
    }
    var title: String {
        (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + character.uppercased()
    }
    var carbonModifiers: UInt32 {
        (flags.contains(.command) ? UInt32(cmdKey) : 0) | (flags.contains(.control) ? UInt32(controlKey) : 0)
            | (flags.contains(.option) ? UInt32(optionKey) : 0) | (flags.contains(.shift) ? UInt32(shiftKey) : 0)
    }
}

enum ShortcutError: LocalizedError {
    case registration(OSStatus), invalid
    var errorDescription: String? {
        switch self {
        case .registration(let status): "This shortcut could not be registered (\(status)). It may already be in use. Choose another combination."
        case .invalid: "Use Command, Control, or Option together with a letter or number."
        }
    }
}

@MainActor
protocol HotKeyRegistrar: AnyObject {
    func register(_ shortcut: LaunchShortcut, id: UInt32) throws
    func unregister(id: UInt32)
}

/// Carbon registers just the requested chord; no keyboard monitoring permission is needed.
@MainActor
final class CarbonHotKeyRegistrar: HotKeyRegistrar {
    private var handler: EventHandlerRef?
    private var registrations: [UInt32: EventHotKeyRef] = [:]
    var onPress: ((UInt32) -> Void)?
    private static let signature: OSType = 0x4558504C // EXPL
    func register(_ shortcut: LaunchShortcut, id: UInt32) throws {
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var hotKey = EventHotKeyID()
                let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                               MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
                guard result == noErr, hotKey.signature == 0x4558504C else { return OSStatus(eventNotHandledErr) }
                // Application event handlers run on AppKit's main event loop.
                MainActor.assumeIsolated {
                    Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(context).takeUnretainedValue().onPress?(hotKey.id)
                }
                return noErr
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { throw ShortcutError.registration(status) }
        }
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, EventHotKeyID(signature: Self.signature, id: id),
                                        GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else { throw ShortcutError.registration(status) }
        registrations[id] = reference
    }
    func unregister(id: UInt32) {
        if let reference = registrations.removeValue(forKey: id) { UnregisterEventHotKey(reference) }
    }
    func shutdown() {
        for reference in registrations.values { UnregisterEventHotKey(reference) }
        registrations.removeAll()
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
}

@MainActor
final class GlobalShortcutController {
    private let registrar: any HotKeyRegistrar
    private var nextID: UInt32 = 0
    private(set) var activeID: UInt32?
    private(set) var activeShortcut: LaunchShortcut?
    init(registrar: any HotKeyRegistrar) { self.registrar = registrar }
    func apply(_ shortcut: LaunchShortcut?) throws {
        guard shortcut != activeShortcut else { return }
        var newID: UInt32?
        if let shortcut {
            guard shortcut.isValid else { throw ShortcutError.invalid }
            nextID &+= 1
            try registrar.register(shortcut, id: nextID)
            newID = nextID
        }
        // Keep the old shortcut working when the replacement cannot be registered.
        if let activeID { registrar.unregister(id: activeID) }
        activeID = newID; activeShortcut = shortcut
    }
}

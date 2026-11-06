import Foundation

/// Keyboard modifiers in a platform-neutral form. Glyph rendering lives here so
/// every shell shows the same string.
public struct KeyModifiers: OptionSet, Equatable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)
    public static let shift = KeyModifiers(rawValue: 1 << 3)

    public var hasAny: Bool { !isEmpty }
}

/// A global hotkey. `keyCode` is the platform virtual key code (Carbon on macOS).
public struct Hotkey: Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: KeyModifiers

    public init(keyCode: UInt32, modifiers: KeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// ⌥⌘D (Carbon keycode 2).
    public static let standard = Hotkey(keyCode: 2, modifiers: [.command, .option])

    /// A hotkey needs at least one modifier; bare keys are rejected rather than
    /// silently promoted.
    public var isValid: Bool { modifiers.hasAny }

    /// Carbon modifier mask (cmdKey | optionKey | ...). No Carbon import needed.
    public var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if modifiers.contains(.command) { value |= 256 }   // cmdKey
        if modifiers.contains(.option) { value |= 2048 }   // optionKey
        if modifiers.contains(.control) { value |= 4096 }  // controlKey
        if modifiers.contains(.shift) { value |= 512 }     // shiftKey
        return value
    }

    public var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        result += KeyCodeNames.name(keyCode)
        return result
    }
}

public enum KeyCodeNames {
    /// Carbon virtual key codes and their labels. Covered keys: letters, digits,
    /// common punctuation, space/return/tab/escape, arrows, F1–F12.
    public static let names: [UInt32: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P",
        12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
        16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6",
        26: "7", 28: "8", 25: "9",
        49: "Space", 36: "Return", 48: "Tab", 53: "Esc", 51: "Delete", 117: "Fwd Delete",
        123: "←", 124: "→", 126: "↑", 125: "↓",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'",
        43: ",", 47: ".", 44: "/", 42: "\\", 50: "`"
    ]

    public static func name(_ keyCode: UInt32) -> String {
        names[keyCode] ?? "Key \(keyCode)"
    }

    /// Carbon modifier key codes, used to ignore bare modifier presses while
    /// recording (macOS value, but harmless data on other platforms).
    public static let modifierKeyCodes: Set<UInt32> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    public static func isModifier(_ keyCode: UInt32) -> Bool {
        modifierKeyCodes.contains(keyCode)
    }
}

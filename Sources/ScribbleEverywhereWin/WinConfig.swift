import Foundation
import WinSDK
import PalimpsestCore

/// Persisted settings, mirroring the macOS store: JSON at
/// %APPDATA%\PalimpsestInk\config.json.
struct WinConfig: Codable {
    /// Windows virtual key code (0x44 = D).
    var hotkeyCode: UInt32 = 0x44
    /// MOD_ALT | MOD_CONTROL | MOD_SHIFT bits (Win32 MOD_* values).
    var hotkeyModifiers: UInt32 = UInt32(MOD_CONTROL) | UInt32(MOD_ALT)
    var paletteColors: [String] = ["#FF3B30FF", "#0072FFFF", "#34C759FF"]
    var paletteIndex: Int = 0
    var pasteTarget: String = PasteTargetPreference.previousApp.rawValue
    /// Pinned paste window, as a decimal HWND. If it no longer matches its
    /// recorded identity, pasting stops until the user selects a target again.
    var pasteOverrideHwnd: String? = nil
    /// Menu label for the pinned window.
    var pasteOverrideTitle: String? = nil
    /// A bare HWND is reusable. Older pins without identity remain visible but
    /// must be explicitly selected again before they can receive a paste.
    var pasteOverrideIdentity: WinWindowTargeting.Identity? = nil
    /// Persisted stop action: nil defaults to copyAndPaste, "clipboard" means copy only.
    var stopAction: String? = nil
    /// Image paste chord. nil and "auto" use Alt+V for Windows Terminal and
    /// Ctrl+V everywhere else. "ctrlV" and "altV" are fixed.
    var pasteChord: String? = nil
    /// Custom names for palette colours, keyed by hex (`#RRGGBBAA`). A
    /// custom name wins over the built-in table; hex is the last resort.
    var colourNames: [String: String] = [:]
    /// Save a PNG of each delivered annotation to disk. Defaults on.
    var saveAnnotations: Bool = true
    /// Where saved annotations go. Empty uses the default folder.
    var annotationFolder: String? = nil
    /// Soften blown-out whites in the capture before ink is composited.
    var paperTone: Bool = true
    /// Floating palette location: "none", "topLeft", or "topRight".
    var floatingPalettePosition: String = "topRight"
    /// Launch at login. Reflected in the shell:startup folder.
    var launchOnStartup: Bool = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case hotkeyCode, hotkeyModifiers, paletteColors, paletteIndex, pasteTarget
        case pasteOverrideHwnd, pasteOverrideTitle, pasteOverrideIdentity, stopAction, pasteChord, colourNames
        case saveAnnotations, annotationFolder, paperTone, floatingPalettePosition, launchOnStartup
    }

    /// Synthesized Decodable does not apply property defaults to missing keys.
    /// Older installs must retain their existing settings when new fields appear.
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hotkeyCode = try values.decodeIfPresent(UInt32.self, forKey: .hotkeyCode) ?? hotkeyCode
        hotkeyModifiers = try values.decodeIfPresent(UInt32.self, forKey: .hotkeyModifiers) ?? hotkeyModifiers
        paletteColors = try values.decodeIfPresent([String].self, forKey: .paletteColors) ?? paletteColors
        paletteIndex = try values.decodeIfPresent(Int.self, forKey: .paletteIndex) ?? paletteIndex
        pasteTarget = try values.decodeIfPresent(String.self, forKey: .pasteTarget) ?? pasteTarget
        pasteOverrideHwnd = try values.decodeIfPresent(String.self, forKey: .pasteOverrideHwnd)
        pasteOverrideTitle = try values.decodeIfPresent(String.self, forKey: .pasteOverrideTitle)
        pasteOverrideIdentity = try values.decodeIfPresent(WinWindowTargeting.Identity.self, forKey: .pasteOverrideIdentity)
        stopAction = try values.decodeIfPresent(String.self, forKey: .stopAction)
        pasteChord = try values.decodeIfPresent(String.self, forKey: .pasteChord)
        colourNames = try values.decodeIfPresent([String: String].self, forKey: .colourNames) ?? colourNames
        saveAnnotations = try values.decodeIfPresent(Bool.self, forKey: .saveAnnotations) ?? saveAnnotations
        annotationFolder = try values.decodeIfPresent(String.self, forKey: .annotationFolder)
        paperTone = try values.decodeIfPresent(Bool.self, forKey: .paperTone) ?? paperTone
        floatingPalettePosition = try values.decodeIfPresent(String.self, forKey: .floatingPalettePosition) ?? floatingPalettePosition
        launchOnStartup = try values.decodeIfPresent(Bool.self, forKey: .launchOnStartup) ?? launchOnStartup
    }

    static func load() -> WinConfig {
        let path = configPath()
        guard let data = FileManager.default.contents(atPath: path) else {
            let fallback = WinConfig()
            fallback.store()
            return fallback
        }
        do {
            let config = try JSONDecoder().decode(WinConfig.self, from: data)
            return config
        } catch {
            WinLog.log("Config decode failed (\(error.localizedDescription)); using defaults")
            return WinConfig()
        }
    }

    @discardableResult
    func store() -> Bool {
        do {
            let data = try JSONEncoder().encode(self)
            let path = Self.configPath()
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            WinLog.log("Config store failed: \(error.localizedDescription)")
            return false
        }
    }

    static func configPath() -> String {
        let base = env("APPDATA") ?? "."
        return "\(base)\\PalimpsestInk\\config.json"
    }

    /// Hotkey label like "Ctrl+Alt+D".
    var hotkeyDisplay: String {
        var result = ""
        if hotkeyModifiers & UInt32(MOD_CONTROL) != 0 { result += "Ctrl+" }
        if hotkeyModifiers & UInt32(MOD_ALT) != 0 { result += "Alt+" }
        if hotkeyModifiers & UInt32(MOD_SHIFT) != 0 { result += "Shift+" }
        if hotkeyModifiers & UInt32(MOD_WIN) != 0 { result += "Win+" }
        result += vkeyName(hotkeyCode)
        return result
    }

    /// Compare keyboard-state modifiers to RegisterHotKey's binding. Flags such
    /// as MOD_NOREPEAT control registration, not which keys must be held.
    func matchesHotkey(key: UInt32, modifiers: UInt32) -> Bool {
        let keys = UInt32(MOD_ALT | MOD_CONTROL | MOD_SHIFT | MOD_WIN)
        return key == hotkeyCode && (modifiers & keys) == (hotkeyModifiers & keys)
    }

    var palette: Palette {
        get {
            let colors = paletteColors.compactMap(RGBA.init(hex:))
            return Palette(colors: colors.isEmpty ? Palette.defaultColors : colors, index: paletteIndex)
        }
        set {
            paletteColors = newValue.colors.map(\.hex)
            paletteIndex = newValue.index
        }
    }

    var pastePreference: PasteTargetPreference {
        PasteTargetPreference(rawValue: pasteTarget) ?? .previousApp
    }

    /// What the tray menu shows as the resolved paste destination.
    var pasteTargetLabel: String {
        if pasteOverrideHwnd != nil, let pasteOverrideTitle, !pasteOverrideTitle.isEmpty {
            return pasteOverrideTitle
        }
        return pastePreference == .frontmostApp ? "Frontmost window" : "Previous window"
    }

    var floatingPosition: WinFloatingPosition {
        WinFloatingPosition(rawValue: floatingPalettePosition) ?? .topRight
    }

    /// The resolved annotations folder, or the default under %APPDATA%.
    var resolvedAnnotationFolder: String {
        if let annotationFolder, !annotationFolder.isEmpty { return annotationFolder }
        return WinHistory.defaultFolder()
    }

    func displayName(for color: RGBA) -> String {
        colourNames[color.hex] ?? WinColourNames.name(for: color)
    }

    /// Empty string clears the custom name, falling back to the built-in table.
    mutating func setName(_ name: String, for color: RGBA) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            colourNames.removeValue(forKey: color.hex)
        } else {
            colourNames[color.hex] = trimmed
        }
    }
}

enum WinFloatingPosition: String, CaseIterable {
    case none
    case topLeft
    case topRight

    var title: String {
        switch self {
        case .none: return "None"
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        }
    }
}

/// Windows virtual-key code -> label for the common keys.
func vkeyName(_ vk: UInt32) -> String {
    if (0x30...0x39).contains(vk) { return String(Character(UnicodeScalar(vk)!)) }
    if (0x41...0x5A).contains(vk) { return String(Character(UnicodeScalar(vk)!)) }
    switch vk {
    case UInt32(VK_SPACE): return "Space"
    case UInt32(VK_RETURN): return "Enter"
    case UInt32(VK_TAB): return "Tab"
    case UInt32(VK_ESCAPE): return "Esc"
    case UInt32(VK_BACK): return "Backspace"
    case UInt32(VK_F1): return "F1"
    case UInt32(VK_F2): return "F2"
    case UInt32(VK_F3): return "F3"
    case UInt32(VK_F4): return "F4"
    case UInt32(VK_F5): return "F5"
    case UInt32(VK_F6): return "F6"
    case UInt32(VK_F7): return "F7"
    case UInt32(VK_F8): return "F8"
    case UInt32(VK_F9): return "F9"
    case UInt32(VK_F10): return "F10"
    case UInt32(VK_F11): return "F11"
    case UInt32(VK_F12): return "F12"
    case UInt32(VK_OEM_COMMA): return ","
    case UInt32(VK_OEM_PERIOD): return "."
    case UInt32(VK_OEM_MINUS): return "-"
    default: return "Key \(vk)"
    }
}

func env(_ name: String) -> String? {
    var buffer = [WCHAR](repeating: 0, count: 1024)
    let count = GetEnvironmentVariableW(name.wide, &buffer, UInt32(buffer.count))
    guard count > 0, count < UInt32(buffer.count) else { return nil }
    return String(decoding: buffer.prefix(Int(count)).map { UInt16($0) }, as: UTF16.self)
}

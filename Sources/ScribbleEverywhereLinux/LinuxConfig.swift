import Foundation
#if canImport(Glibc)
import Glibc
#endif
import PalimpsestCore

/// Linux settings persisted as JSON at ~/.config/palimpsest-ink/config.json,
/// mirroring WinConfig/macOS SettingsStore.
struct LinuxConfig: Codable {
    var paletteColors: [String] = ["#FF3B30FF", "#0072FFFF", "#34C759FF"]
    var paletteIndex: Int = 0
    var pasteTarget: String = PasteTargetPreference.previousApp.rawValue
    var pasteOverride: String?
    var pasteOverrideName: String?
    /// `none`, `topLeft`, or `topRight`. Missing values default to top-right
    /// so the overlay swatches are visible without a Settings panel.
    var floatingPalette: String? = LinuxFloatingPalette.topRight.rawValue
    /// `clipboard` or `copyAndPaste`. Missing values default to copy-and-paste
    /// so a barrel press drops the annotation into the window you were in.
    var action: String? = "copyAndPaste"
    var saveAnnotations: Bool? = true
    var paperTone: Bool? = true
    var colourNames: [String: String]? = [:]
    var annotationFolder: String?
    var launchOnStartup: Bool? = false
    /// Legacy preference, decoded for compatibility. Idle pen behavior is
    /// controlled by Hyprland rather than this stored value.
    var penMouseMode: Bool? = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case paletteColors, paletteIndex, pasteTarget, pasteOverride, pasteOverrideName
        case floatingPalette, action, saveAnnotations, paperTone, colourNames
        case annotationFolder, launchOnStartup, penMouseMode
    }

    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        paletteColors = try values.decodeIfPresent([String].self, forKey: .paletteColors) ?? paletteColors
        paletteIndex = try values.decodeIfPresent(Int.self, forKey: .paletteIndex) ?? paletteIndex
        pasteTarget = try values.decodeIfPresent(String.self, forKey: .pasteTarget) ?? pasteTarget
        pasteOverride = try values.decodeIfPresent(String.self, forKey: .pasteOverride)
        pasteOverrideName = try values.decodeIfPresent(String.self, forKey: .pasteOverrideName)
        floatingPalette = try values.decodeIfPresent(String.self, forKey: .floatingPalette) ?? floatingPalette
        action = try values.decodeIfPresent(String.self, forKey: .action) ?? action
        saveAnnotations = try values.decodeIfPresent(Bool.self, forKey: .saveAnnotations) ?? saveAnnotations
        paperTone = try values.decodeIfPresent(Bool.self, forKey: .paperTone) ?? paperTone
        colourNames = try values.decodeIfPresent([String: String].self, forKey: .colourNames) ?? colourNames
        annotationFolder = try values.decodeIfPresent(String.self, forKey: .annotationFolder)
        launchOnStartup = try values.decodeIfPresent(Bool.self, forKey: .launchOnStartup) ?? launchOnStartup
        penMouseMode = try values.decodeIfPresent(Bool.self, forKey: .penMouseMode) ?? penMouseMode
    }

    static func load(from file: String = path()) -> LinuxConfig {
        guard let data = FileManager.default.contents(atPath: file) else {
            let fallback = LinuxConfig()
            fallback.store(at: file)
            return fallback
        }
        do {
            return try JSONDecoder().decode(LinuxConfig.self, from: data)
        } catch {
            LinuxLog.log("Config decode failed: \(error)")
            return LinuxConfig()
        }
    }

    @discardableResult
    func store(at file: String = Self.path()) -> Bool {
        do {
            let data = try JSONEncoder().encode(self)
            try FileManager.default.createDirectory(
                atPath: (file as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try data.write(to: URL(fileURLWithPath: file), options: .atomic)
            return true
        } catch {
            LinuxLog.log("Config store failed: \(error)")
            return false
        }
    }

    static func path() -> String {
        let base = env("XDG_CONFIG_HOME") ?? "\(env("HOME") ?? ".")/.config"
        return "\(base)/palimpsest-ink/config.json"
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

    var floatingPalettePosition: LinuxFloatingPalette {
        get { LinuxFloatingPalette(stored: floatingPalette) }
        set { floatingPalette = newValue.rawValue }
    }

    var pasteMenuTitle: String {
        pasteMenuTitle(pinAvailable: true)
    }

    /// Mirrors the Windows tray: a pinned window that has since closed is
    /// flagged so the user knows to pick a new target instead of trusting
    /// a stale name that paste will refuse to fall back from.
    func pasteMenuTitle(pinAvailable: Bool) -> String {
        if let override = pasteOverride, !override.isEmpty, !pinAvailable {
            return "\(pasteMenuTitle(pinAvailable: true)) — reselect"
        }
        if let name = pasteOverrideName, let override = pasteOverride, !override.isEmpty, !name.isEmpty {
            return name
        }
        if let override = pasteOverride, !override.isEmpty {
            return override
        }
        return pastePreference == .previousApp ? "Previous window" : "Frontmost window"
    }

    var deliveryAction: LinuxDeliveryAction {
        get { LinuxDeliveryAction(stored: action) }
        set { action = newValue.rawValue }
    }

    var saveToDisk: Bool { saveAnnotations ?? true }
    var softenPaper: Bool { paperTone ?? true }
    var names: [String: String] {
        get { colourNames ?? [:] }
        set { colourNames = newValue }
    }

    var historyFolder: String {
        get {
            if let annotationFolder, !annotationFolder.isEmpty { return annotationFolder }
            return LinuxHistory.defaultFolder
        }
        set { annotationFolder = newValue }
    }

    func displayName(for color: RGBA) -> String {
        names[color.hex] ?? LinuxColourNames.name(for: color)
    }
}

enum LinuxDeliveryAction: String {
    case clipboard
    case copyAndPaste

    init(stored: String?) {
        switch stored ?? "" {
        case "clipboard", "copy": self = .clipboard
        default: self = .copyAndPaste
        }
    }

    init?(command: String) {
        switch command {
        case "clipboard", "copy": self = .clipboard
        case "copyAndPaste", "copy-and-paste", "paste": self = .copyAndPaste
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .clipboard: return "Copy to clipboard"
        case .copyAndPaste: return "Copy and paste"
        }
    }
}

extension LinuxColourNames {
    /// Presets beyond the three defaults. `colour-add` without a hex uses the
    /// first of these that is not already in the palette.
    static let extras: [(RGBA, String)] = [
        (RGBA(r: 255, g: 149, b: 0), "Orange"),
        (RGBA(r: 175, g: 82, b: 222), "Purple"),
        (RGBA(r: 255, g: 214, b: 10), "Yellow"),
        (RGBA(r: 90, g: 200, b: 250), "Cyan"),
        (RGBA(r: 255, g: 45, b: 85), "Pink"),
        (RGBA(r: 255, g: 255, b: 255), "White"),
        (RGBA(r: 0, g: 0, b: 0), "Black")
    ]

    static func unusedExtras(in palette: Palette) -> [[String: String]] {
        extras.compactMap { color, name in
            palette.colors.contains(color) ? nil : ["hex": color.hex, "name": name]
        }
    }

    static func nextUnusedExtra(in palette: Palette) -> RGBA? {
        extras.first { color, _ in !palette.colors.contains(color) }?.0
    }
}

enum LinuxLog {
    static var filePath: String {
        let base = env("XDG_STATE_HOME") ?? "\(env("HOME") ?? ".")/.local/state"
        return "\(base)/palimpsest-ink/daemon.log"
    }

    static func log(_ message: String) {
        let line = "[\(Int(Date().timeIntervalSince1970))] \(message)\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
    }
}

func env(_ name: String) -> String? {
    #if canImport(Glibc)
    guard let value = getenv(name) else { return nil }
    return String(cString: value)
    #else
    return ProcessInfo.processInfo.environment[name]
    #endif
}

func unixAddress(path: String) -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        let count = min(bytes.count, destination.count)
        guard count > 0 else { return }
        bytes.withUnsafeBytes { source in
            guard let from = source.baseAddress, let to = destination.baseAddress else { return }
            to.copyMemory(from: from, byteCount: count)
        }
    }
    return address
}

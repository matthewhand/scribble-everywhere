import Foundation
import Combine
import ServiceManagement
import PalimpsestCore

enum FloatingPalettePosition: String, CaseIterable {
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

enum DeliveryAction: String, CaseIterable {
    case clipboard
    case copyAndPaste

    var title: String {
        switch self {
        case .clipboard: return "Copy to clipboard"
        case .copyAndPaste: return "Copy and paste"
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults
    private let updateLoginItem: (Bool) throws -> Void
    private let loginStatus: () -> SMAppService.Status
    private var changingLoginItem = false
    @Published private(set) var startupMessage: String? = nil
    private enum Key {
        static let hotkeyCode = "hotkey.keyCode"
        static let hotkeyModifiers = "hotkey.modifiers"
        static let pasteTarget = "paste.preference"
        static let pasteOverrideApp = "paste.overrideApp"
        static let pasteOverrideAppName = "paste.overrideAppName"
        static let paletteColors = "ink.palette"
        static let paletteIndex = "ink.paletteIndex"
        static let colourNames = "ink.colourNames"
        static let launchOnStartup = "launch.onStartup"
        static let action = "delivery.action"
        static let saveAnnotations = "history.saveAnnotations"
        static let floatingPalettePosition = "palette.floatingPosition"
        static let annotationFolder = "history.folder"
        static let paperTone = "export.paperTone"
        static let penMouseMode = "input.penMouseMode"
    }

    @Published var hotkey: Hotkey {
        didSet { persistHotkey() }
    }

    @Published var pasteTarget: PasteTargetPreference {
        didSet { defaults.set(pasteTarget.rawValue, forKey: Key.pasteTarget) }
    }

    /// A specific app pinned from the applet menu; always wins over
    /// `pasteTarget` while set. `nil` = "previous window" default behaviour.
    @Published var pasteOverrideAppID: String? {
        didSet {
            if let pasteOverrideAppID {
                defaults.set(pasteOverrideAppID, forKey: Key.pasteOverrideApp)
            } else {
                defaults.removeObject(forKey: Key.pasteOverrideApp)
            }
        }
    }

    /// Human-readable name of the pinned app, for menus and Settings.
    @Published var pasteOverrideAppName: String? {
        didSet {
            if let pasteOverrideAppName {
                defaults.set(pasteOverrideAppName, forKey: Key.pasteOverrideAppName)
            } else {
                defaults.removeObject(forKey: Key.pasteOverrideAppName)
            }
        }
    }

    @Published var launchOnStartup: Bool {
        didSet { updateLaunchOnStartup() }
    }

    @Published var action: DeliveryAction {
        didSet { defaults.set(action.rawValue, forKey: Key.action) }
    }

    @Published var saveAnnotations: Bool {
        didSet { defaults.set(saveAnnotations, forKey: Key.saveAnnotations) }
    }

    @Published var floatingPalettePosition: FloatingPalettePosition {
        didSet { defaults.set(floatingPalettePosition.rawValue, forKey: Key.floatingPalettePosition) }
    }

    @Published var annotationFolder: URL {
        didSet { defaults.set(annotationFolder.path, forKey: Key.annotationFolder) }
    }

    /// Softens the blown-out white areas of captured images before they are
    /// exported. Ink colours are unaffected - the tone is applied to the
    /// capture, before the ink is composited on top.
    @Published var paperTone: Bool {
        didSet { defaults.set(paperTone, forKey: Key.paperTone) }
    }

    @Published var penMouseMode: Bool {
        didSet { defaults.set(penMouseMode, forKey: Key.penMouseMode) }
    }

    @Published var palette: Palette {
        didSet { persistPalette() }
    }

    /// Custom names for palette colours, keyed by hex (`#RRGGBBAA`). A
    /// custom name wins over ColourNames' built-in table; hex is the last
    /// resort.
    @Published var colourNames: [String: String] {
        didSet { defaults.set(colourNames, forKey: Key.colourNames) }
    }

    init(defaults: UserDefaults = .standard,
         updateLoginItem: @escaping (Bool) throws -> Void = { enabled in
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
         }, loginStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status }) {
        self.defaults = defaults
        self.updateLoginItem = updateLoginItem
        self.loginStatus = loginStatus
        if defaults.object(forKey: Key.hotkeyCode) != nil,
           let code = UInt32(exactly: defaults.integer(forKey: Key.hotkeyCode)),
           code <= 127,
           !KeyCodeNames.isModifier(code),
           defaults.integer(forKey: Key.hotkeyModifiers) > 0,
           defaults.integer(forKey: Key.hotkeyModifiers) & ~15 == 0 {
            hotkey = Hotkey(keyCode: code, modifiers: KeyModifiers(rawValue: defaults.integer(forKey: Key.hotkeyModifiers)))
        } else {
            hotkey = .standard
        }
        pasteTarget = PasteTargetPreference(
            rawValue: defaults.string(forKey: Key.pasteTarget) ?? ""
        ) ?? .previousApp
        pasteOverrideAppID = defaults.string(forKey: Key.pasteOverrideApp)
        pasteOverrideAppName = defaults.string(forKey: Key.pasteOverrideAppName)
        let status = loginStatus()
        launchOnStartup = status == .enabled || status == .requiresApproval
        action = DeliveryAction(rawValue: defaults.string(forKey: Key.action) ?? "") ?? .copyAndPaste
        saveAnnotations = defaults.object(forKey: Key.saveAnnotations) == nil || defaults.bool(forKey: Key.saveAnnotations)
        floatingPalettePosition = FloatingPalettePosition(rawValue: defaults.string(forKey: Key.floatingPalettePosition) ?? "") ?? .topRight
        let defaultFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PalimpsestInk", isDirectory: true)
            .appendingPathComponent("Annotations", isDirectory: true)
        annotationFolder = URL(fileURLWithPath: defaults.string(forKey: Key.annotationFolder) ?? defaultFolder.path)
        paperTone = defaults.object(forKey: Key.paperTone) == nil || defaults.bool(forKey: Key.paperTone)
        penMouseMode = defaults.object(forKey: Key.penMouseMode) == nil || defaults.bool(forKey: Key.penMouseMode)

        let colors = (defaults.array(forKey: Key.paletteColors) as? [String])?
            .compactMap(RGBA.init(hex:)) ?? Palette.defaultColors
        palette = Palette(colors: colors, index: defaults.integer(forKey: Key.paletteIndex))
        colourNames = (defaults.dictionary(forKey: Key.colourNames) as? [String: String]) ?? [:]
        startupMessage = status == .requiresApproval
            ? "Allow ScribbleEverywhere in System Settings → General → Login Items." : nil
    }

    private func updateLaunchOnStartup() {
        guard !changingLoginItem else { return }
        changingLoginItem = true
        defer { changingLoginItem = false }
        do {
            try updateLoginItem(launchOnStartup)
            startupMessage = loginStatus() == .requiresApproval
                ? "Allow ScribbleEverywhere in System Settings → General → Login Items." : nil
        } catch {
            startupMessage = "Could not change login setting: \(error.localizedDescription)"
        }
        let status = loginStatus()
        launchOnStartup = status == .enabled || status == .requiresApproval
        defaults.set(launchOnStartup, forKey: Key.launchOnStartup)
    }

    private func persistHotkey() {
        defaults.set(Int(hotkey.keyCode), forKey: Key.hotkeyCode)
        defaults.set(hotkey.modifiers.rawValue, forKey: Key.hotkeyModifiers)
    }

    private func persistPalette() {
        defaults.set(palette.colors.map(\.hex), forKey: Key.paletteColors)
        defaults.set(palette.index, forKey: Key.paletteIndex)
    }

    // MARK: Palette edits (the Settings swatch row)

    func selectColour(at index: Int) {
        var palette = self.palette
        palette.select(index)
        self.palette = palette
    }

    func removeColour(at index: Int) {
        var palette = self.palette
        guard palette.colors.indices.contains(index) else { return }
        let removed = palette.colors[index]
        palette.remove(at: index)
        self.palette = palette
        if !palette.colors.contains(removed) {
            colourNames.removeValue(forKey: removed.hex)
        }
    }

    /// Replaces a swatch in place. A custom name travels with the swatch to
    /// its new colour so a recolour does not drop the label.
    func replaceColour(at index: Int, with color: RGBA) {
        var palette = self.palette
        guard palette.colors.indices.contains(index) else { return }
        let old = palette.colors[index]
        let oldName = colourNames[old.hex]
        palette.replace(at: index, with: color)
        self.palette = palette
        guard old != color, palette.colors[index] == color else { return }
        if let oldName { setName(oldName, for: color) }
        // A continuously dragged colour picker can generate hundreds of
        // intermediate colours; keep an old name only if another swatch still
        // references that colour.
        if !palette.colors.contains(old) {
            colourNames.removeValue(forKey: old.hex)
        }
    }

    // MARK: Colour names

    func customName(for color: RGBA) -> String? {
        colourNames[color.hex]
    }

    func displayName(for color: RGBA) -> String {
        colourNames[color.hex] ?? ColourNames.name(for: color)
    }

    /// Empty string clears the custom name, falling back to the built-in
    /// table then hex.
    func setName(_ name: String, for color: RGBA) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            colourNames.removeValue(forKey: color.hex)
        } else {
            colourNames[color.hex] = trimmed
        }
    }
}

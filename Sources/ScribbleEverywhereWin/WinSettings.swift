import Foundation
import WinSDK
import PalimpsestCore

/// Native settings window: edits a draft until Save, keeping the tray available.
@MainActor
final class WinSettings {
    private var hwnd: HWND?
    private var controls: [Int: HWND] = [:]
    private var draft = WinConfig()
    private var scale = 1.0
    var onSave: ((WinConfig) -> String?)?
    var onMenu: ((HWND) -> Void)?
    private static let className = "PalimpsestInkSettings"
    private static let modifierMasks: [UInt32] = [3, 6, 5, 7, 2, 1, 4, 10, 9, 12, 11, 13, 14, 15, 8]
    private enum ID {
        static let save = 1, close = 2, status = 3, ink = 10, modifiers = 11, key = 12
        static let action = 13, folder = 14, position = 15, autosave = 16, paper = 17
        static let hex = 18, name = 19, add = 20, update = 21, remove = 22, browse = 23
    }

    func show(config: WinConfig) {
        draft = config
        if hwnd == nil { create() }
        guard let hwnd else { return }
        select(ID.modifiers, Self.modifierMasks.firstIndex(of: config.hotkeyModifiers & 15) ?? 0)
        setText(ID.key, vkeyName(config.hotkeyCode))
        select(ID.action, config.stopAction == "clipboard" ? 1 : 0)
        select(ID.position, WinFloatingPosition.allCases.firstIndex(of: config.floatingPosition) ?? 2)
        setText(ID.folder, config.resolvedAnnotationFolder)
        check(ID.autosave, config.saveAnnotations)
        check(ID.paper, config.paperTone)
        refreshPalette()
        setText(ID.status, "")
        ShowWindow(hwnd, SW_SHOWNORMAL)
        _ = SetForegroundWindow(hwnd)
    }

    private func create() {
        var wc = WNDCLASSEXW()
        wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        wc.lpfnWndProc = Self.wndProc
        wc.hInstance = GetModuleHandleW(nil)
        wc.hbrBackground = GetSysColorBrush(Int32(COLOR_BTNFACE))
        wc.hCursor = LoadCursorW(nil, UnsafePointer(bitPattern: 32512))
        Self.className.wide.withUnsafeBufferPointer {
            wc.lpszClassName = $0.baseAddress
            _ = RegisterClassExW(&wc)
        }
        let display = WinDisplays.all().first
        scale = display?.scale ?? 1
        hwnd = CreateWindowExW(DWORD(WS_EX_CONTROLPARENT), Self.className.wide,
            "ScribbleEverywhere — Settings".wide, DWORD(WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX),
            Int32((display?.frame.minX ?? 0) + 80 * scale), Int32((display?.frame.minY ?? 0) + 60 * scale),
            px(610), px(610), nil, nil, GetModuleHandleW(nil), nil)
        guard let hwnd else { return }
        Self.registry[hwnd] = self
        label("Global shortcut", 20, 18, 250)
        combo(ID.modifiers, 20, 42, 205, Self.modifierMasks.map { mask in
            var names: [String] = []
            if mask & UInt32(MOD_CONTROL) != 0 { names.append("Ctrl") }
            if mask & UInt32(MOD_ALT) != 0 { names.append("Alt") }
            if mask & UInt32(MOD_SHIFT) != 0 { names.append("Shift") }
            if mask & UInt32(MOD_WIN) != 0 { names.append("Win") }
            return names.joined(separator: "+")
        })
        edit(ID.key, 240, 42, 80)
        label("Key: A–Z, 0–9, F1–F12", 335, 45, 245)
        label("When stopping annotation", 20, 85, 400)
        combo(ID.action, 20, 110, 350, ["Copy and paste", "Copy to clipboard"])
        button(ID.autosave, "Save annotations to disk", 20, 153, 265, DWORD(BS_AUTOCHECKBOX))
        button(ID.paper, "Soften white backgrounds", 295, 153, 285, DWORD(BS_AUTOCHECKBOX))
        label("Annotations folder", 20, 197, 400)
        edit(ID.folder, 20, 223, 460)
        button(ID.browse, "Browse…", 490, 222, 90)
        label("Floating palette", 20, 268, 170)
        combo(ID.position, 195, 263, 220, WinFloatingPosition.allCases.map(\.title))
        _ = control("STATIC", "", 0, 20, 307, 560, 2, DWORD(SS_ETCHEDHORZ))
        label("Ink colour", 20, 324, 260)
        combo(ID.ink, 20, 350, 270, [])
        label("Hex colour", 310, 324, 200)
        edit(ID.hex, 310, 350, 160)
        label("Colour name", 20, 390, 270)
        edit(ID.name, 20, 415, 270)
        button(ID.add, "Add", 310, 414, 80)
        button(ID.update, "Update", 400, 414, 80)
        button(ID.remove, "Remove", 490, 414, 90)
        _ = control("STATIC", "", ID.status, 20, 465, 560, 48)
        button(ID.save, "Save", 390, 533, 90, DWORD(BS_DEFPUSHBUTTON))
        button(ID.close, "Close", 490, 533, 90)
    }

    private func px(_ value: Int) -> Int32 { Int32((Double(value) * scale).rounded()) }

    @discardableResult
    private func control(_ kind: String, _ title: String, _ id: Int, _ x: Int, _ y: Int,
                         _ width: Int, _ height: Int, _ style: DWORD = 0) -> HWND? {
        guard let hwnd else { return nil }
        let child = CreateWindowExW(0, kind.wide, title.wide,
            DWORD(WS_CHILD | WS_VISIBLE) | style, px(x), px(y), px(width), px(height),
            hwnd, id == 0 ? nil : HMENU(bitPattern: id), GetModuleHandleW(nil), nil)
        if let child {
            if id != 0 { controls[id] = child }
            if let font = WinTrayMenu.getMenuFont() {
                _ = SendMessageW(child, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: font)), 1)
            }
        }
        return child
    }

    private func label(_ title: String, _ x: Int, _ y: Int, _ width: Int) {
        _ = control("STATIC", title, 0, x, y, width, 23)
    }
    private func edit(_ id: Int, _ x: Int, _ y: Int, _ width: Int) {
        _ = control("EDIT", "", id, x, y, width, 28, DWORD(WS_BORDER | WS_TABSTOP | ES_AUTOHSCROLL))
    }
    private func button(_ id: Int, _ title: String, _ x: Int, _ y: Int, _ width: Int, _ style: DWORD = 0) {
        _ = control("BUTTON", title, id, x, y, width, 28, DWORD(WS_TABSTOP) | style)
    }
    private func combo(_ id: Int, _ x: Int, _ y: Int, _ width: Int, _ entries: [String]) {
        _ = control("COMBOBOX", "", id, x, y, width, 200, DWORD(WS_TABSTOP | WS_VSCROLL | CBS_DROPDOWNLIST))
        for entry in entries { append(id, entry) }
    }
    private func append(_ id: Int, _ value: String) {
        guard let child = controls[id] else { return }
        value.wide.withUnsafeBufferPointer {
            _ = SendMessageW(child, UINT(CB_ADDSTRING), 0, LPARAM(Int(bitPattern: $0.baseAddress)))
        }
    }
    private func select(_ id: Int, _ index: Int) {
        _ = SendMessageW(controls[id], UINT(CB_SETCURSEL), WPARAM(index), 0)
    }
    private func selected(_ id: Int) -> Int { Int(SendMessageW(controls[id], UINT(CB_GETCURSEL), 0, 0)) }
    private func check(_ id: Int, _ value: Bool) {
        _ = SendMessageW(controls[id], UINT(BM_SETCHECK), WPARAM(value ? BST_CHECKED : BST_UNCHECKED), 0)
    }
    private func checked(_ id: Int) -> Bool { SendMessageW(controls[id], UINT(BM_GETCHECK), 0, 0) == LRESULT(BST_CHECKED) }
    private func setText(_ id: Int, _ value: String) { _ = SetWindowTextW(controls[id], value.wide) }
    private func text(_ id: Int) -> String {
        let length = GetWindowTextLengthW(controls[id])
        var buffer = [WCHAR](repeating: 0, count: Int(length) + 1)
        _ = GetWindowTextW(controls[id], &buffer, length + 1)
        return buffer.string
    }

    private func refreshPalette() {
        _ = SendMessageW(controls[ID.ink], UINT(CB_RESETCONTENT), 0, 0)
        for colour in draft.palette.colors { append(ID.ink, draft.displayName(for: colour)) }
        select(ID.ink, draft.palette.index)
        loadColour()
    }
    private func loadColour() {
        let index = selected(ID.ink)
        guard draft.palette.colors.indices.contains(index) else { return }
        let colour = draft.palette.colors[index]
        setText(ID.hex, String(colour.hex.prefix(7)))
        setText(ID.name, draft.displayName(for: colour))
    }
    private func changeColour(_ action: Int) {
        var palette = draft.palette
        let index = selected(ID.ink)
        if action == ID.remove {
            guard palette.colors.count > 1 else { setText(ID.status, "Keep at least one ink colour."); return }
            palette.remove(at: index)
        } else {
            guard let colour = RGBA(hex: text(ID.hex).trimmingCharacters(in: .whitespaces)), colour.a == 255 else {
                setText(ID.status, "Enter an opaque colour, for example #34C759."); return
            }
            if action == ID.add { palette.add(colour) } else { palette.replace(at: index, with: colour) }
            draft.setName(text(ID.name), for: colour)
        }
        draft.palette = palette
        refreshPalette()
        setText(ID.status, "Colour changed. Choose Save to apply.")
    }

    private func save() {
        guard let colour = RGBA(hex: text(ID.hex).trimmingCharacters(in: .whitespaces)), colour.a == 255 else {
            setText(ID.status, "Enter an opaque colour, for example #34C759."); return
        }
        var editedPalette = draft.palette
        editedPalette.replace(at: selected(ID.ink), with: colour)
        draft.palette = editedPalette
        draft.setName(text(ID.name), for: colour)
        let keyText = text(ID.key).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = Self.keyCode(keyText) ?? (keyText == vkeyName(draft.hotkeyCode) ? draft.hotkeyCode : nil) else {
            setText(ID.status, "Choose a letter, digit or function key for the shortcut."); return
        }
        let modifierIndex = selected(ID.modifiers)
        guard Self.modifierMasks.indices.contains(modifierIndex) else { return }
        draft.hotkeyCode = key
        draft.hotkeyModifiers = Self.modifierMasks[modifierIndex]
        draft.stopAction = selected(ID.action) == 1 ? "clipboard" : "copyAndPaste"
        draft.saveAnnotations = checked(ID.autosave)
        draft.paperTone = checked(ID.paper)
        let folder = text(ID.folder).trimmingCharacters(in: .whitespacesAndNewlines)
        draft.annotationFolder = folder.isEmpty ? nil : folder
        let position = selected(ID.position)
        if WinFloatingPosition.allCases.indices.contains(position) {
            draft.floatingPalettePosition = WinFloatingPosition.allCases[position].rawValue
        }
        var palette = draft.palette
        palette.select(selected(ID.ink))
        draft.palette = palette
        let error = onSave?(draft)
        if error == nil { refreshPalette() }
        setText(ID.status, error ?? "Saved.")
    }

    static func keyCode(_ value: String) -> UInt32? {
        let key = value.uppercased()
        if key.utf8.count == 1, let ascii = key.utf8.first,
           (65...90).contains(ascii) || (48...57).contains(ascii) { return UInt32(ascii) }
        if key.hasPrefix("F"), let number = Int(key.dropFirst()), (1...12).contains(number) {
            return UInt32(VK_F1) + UInt32(number - 1)
        }
        return ["SPACE": UInt32(VK_SPACE), "ENTER": UInt32(VK_RETURN), "TAB": UInt32(VK_TAB), "ESC": UInt32(VK_ESCAPE)][key]
    }

    private func browse() {
        let initialized = OleInitialize(nil)
        defer { if initialized >= 0 { OleUninitialize() } }
        var buffer = [WCHAR](repeating: 0, count: 260)
        let title = "Choose annotations folder".wide
        buffer.withUnsafeMutableBufferPointer { name in
            title.withUnsafeBufferPointer { caption in
                var info = BROWSEINFOW()
                info.hwndOwner = hwnd
                info.pszDisplayName = name.baseAddress
                info.lpszTitle = caption.baseAddress
                info.ulFlags = UINT(BIF_RETURNONLYFSDIRS | (initialized >= 0 ? BIF_NEWDIALOGSTYLE : 0))
                guard let item = SHBrowseForFolderW(&info) else { return }
                defer { CoTaskMemFree(UnsafeMutableRawPointer(item)) }
                var path = [WCHAR](repeating: 0, count: 260)
                if SHGetPathFromIDListW(item, &path) { setText(ID.folder, path.string) }
            }
        }
    }

    nonisolated static func filterMessage(_ message: inout MSG) -> Bool {
        MainActor.assumeIsolated {
            for window in registry.keys where IsWindowVisible(window) {
                if IsDialogMessageW(window, &message) { return true }
            }
            return false
        }
    }
    nonisolated(unsafe) private static var registry: [HWND: WinSettings] = [:]
    nonisolated private static let wndProc: WNDPROC = { hwnd, message, wParam, lParam in
        guard let hwnd else { return DefWindowProcW(nil, message, wParam, lParam) }
        if message == UINT(WM_DRAWITEM) || message == UINT(WM_MEASUREITEM) {
            return WinController.trayWndProc(hwnd, message, wParam, lParam)
        }
        if message == UINT(WM_COMMAND), Int(wParam & 0xFFFF) >= 1000 {
            return WinController.trayWndProc(hwnd, message, wParam, lParam)
        }
        return MainActor.assumeIsolated {
            guard let settings = registry[hwnd] else { return DefWindowProcW(hwnd, message, wParam, lParam) }
            switch message {
            case UINT(WM_CLOSE): ShowWindow(hwnd, SW_HIDE); return 0
            case UINT(WM_CONTEXTMENU): settings.onMenu?(hwnd); return 0
            case UINT(WM_COMMAND):
                let id = Int(wParam & 0xFFFF)
                switch id {
                case ID.save: settings.save()
                case ID.close: ShowWindow(hwnd, SW_HIDE)
                case ID.browse: settings.browse()
                case ID.add, ID.update, ID.remove: settings.changeColour(id)
                case ID.ink:
                    if UInt(wParam >> 16) == UInt(CBN_SELCHANGE) { settings.loadColour() }
                default: break
                }
                return 0
            default: return DefWindowProcW(hwnd, message, wParam, lParam)
            }
        }
    }
}

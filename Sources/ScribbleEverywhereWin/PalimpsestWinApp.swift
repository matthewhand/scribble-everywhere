import Foundation
import WinSDK
import PalimpsestCore

/// Windows controller: owns config, overlay, capture and the systray icon.
@MainActor
final class WinController {
    static let shared = WinController()
    static var isolatedValidation = false

    private(set) var config: WinConfig
    private let overlay = WinOverlay()
    private let capturer = WinScreenCapturer()
    private let clipboard = WinClipboard()
    private let paster = WinPaster()
    private let canvas = StrokeCanvas()
    private let paletteBar = WinFloatingPalette()
    private var settingsWindow: WinSettings?
    private let history = WinHistory(folder: WinConfig.load().resolvedAnnotationFolder)

    private var annotating = false
    private var rendering = false
    private var previousHwnd: HWND?
    private var previousWindowIdentity: WinWindowTargeting.Identity?
    private var annotationDisplayId: UInt32?
    private var notificationIconData: NOTIFYICONDATAW?
    /// Track whether the hotkey was successfully registered.
    static var hotkeyStatus = "unknown"

    private init() {
        config = WinConfig.load()
        canvas.ink = config.palette.current
    }

    // MARK: Setup

    func start() {
        overlay.attach(canvas: canvas)
        overlay.onStrokeChanged = { }
        overlay.onCancel = { [weak self] in self?.cancelCapture() }
        overlay.onUndo = { [weak self] in self?.undo() }
        overlay.onClear = { [weak self] in self?.clear() }
        overlay.onCopy = { [weak self] in self?.copyToClipboard() }
        overlay.onCopyAndPaste = { [weak self] in self?.copyAndPaste() }
        overlay.onToggle = { [weak self] in self?.toggleCaptureMode() }
        overlay.matchesToggleHotkey = { [weak self] key, modifiers in
            self?.config.matchesHotkey(key: key, modifiers: modifiers) ?? false
        }
        paletteBar.onSelect = { [weak self] index in self?.selectInkColour(index) }
        paletteBar.onClear = { [weak self] in self?.clear() }
        paletteBar.onSave = { [weak self] in self?.saveAnnotation() }
        paletteBar.onStop = { [weak self] in self?.toggleCaptureMode() }

        if !Self.isolatedValidation { registerHotkey() }
        addTrayIcon()
        clipboard.owner = Self.trayWindow
        if !Self.isolatedValidation && !WinAutostart.migrateExistingShortcut() { WinLog.log("Legacy startup shortcut migration failed") }
        // The F20 hook handles supported pen-button events. A separately
        // configured PenService launch also signals an existing instance.
        // Tip button: the barrel switch beside the nib. See SurfacePenButton.
        if !Self.isolatedValidation { SurfacePenButton.install() }
        if WinPenShortcut.openSettingsOnLaunch {
            showSettings()
        } else if WinPenShortcut.openOnLaunch {
            toggleCaptureMode()
        }
        for display in WinDisplays.all() {
            WinLog.log("display id=\(display.id) origin=(\(display.frame.minX),\(display.frame.minY)) size=\(display.frame.width)x\(display.frame.height) scale=\(display.scale)")
        }
        WinLog.log("paste windows \(WinWindowTargeting.visibleWindows().count) target \(config.pasteTargetLabel)")
        WinLog.log("Palimpsest Win started (hotkey \(config.hotkeyDisplay))")
    }

    private func registerHotkey() {
        let modifiers = UINT(config.hotkeyModifiers) | UINT(MOD_NOREPEAT)
        let vk = UINT(config.hotkeyCode)
        // Reuse id 1 for the annotation toggle.
        let registered = RegisterHotKey(nil, 1, modifiers, vk)
        Self.hotkeyStatus = registered ? "OK (\(config.hotkeyDisplay))" : "UNAVAILABLE (conflict)"
        WinLog.log("RegisterHotKey \(config.hotkeyDisplay) ok=\(registered) err=\(GetLastError())")
    }

    // MARK: Tray icon

    private func addTrayIcon() {
        var data = NOTIFYICONDATAW()
        data.cbSize = UINT32(MemoryLayout<NOTIFYICONDATAW>.size)
        data.hWnd = Self.trayWindow
        data.uID = 1
        data.uFlags = UINT(NIF_MESSAGE | NIF_ICON | NIF_TIP)
        data.uCallbackMessage = Self.WM_APP_TRAY
        data.hIcon = WinTrayIcon.make() ?? LoadIconW(nil, UnsafePointer(bitPattern: 32512))
        copyIntoFixedField(&data.szTip, "ScribbleEverywhere".wide)
        _ = Shell_NotifyIconW(UINT(NIM_DELETE), &data)
        let added = Shell_NotifyIconW(UINT(NIM_ADD), &data)
        WinLog.log("tray NIM_ADD=\(added) icon=\(data.hIcon != nil)")
        notificationIconData = data
        WinHUD.tray = Self.trayWindow
        if !Self.isolatedValidation {
            WinPenShortcut.noteTrayWindow(Self.trayWindow)
            PenBarrel.install(hwnd: Self.trayWindow)
        }
    }

    nonisolated(unsafe) private static var trayWindow: HWND = {
        registerTrayClass()
        return CreateWindowExW(
            0, trayClassName.wide, "PalimpsestTray".wide, 0,
            0, 0, 0, 0, nil, nil, GetModuleHandleW(nil), nil
        )!
    }()

    /// Current owner-draw menu renderer, set when the menu is shown.
    nonisolated(unsafe) private static var currentMenuRenderer: WinTrayMenu?

    nonisolated private static let trayClassName = "PalimpsestTrayWindow"
    nonisolated static let WM_APP_TRAY: UINT = UINT(WM_APP) + 1
    /// Posted from the tray right-click so TrackPopupMenu is not nested inside
    /// Explorer's SendMessage.
    nonisolated static let WM_APP_SHOW_MENU: UINT = UINT(WM_APP) + 2
    nonisolated static let WM_APP_OPEN_SETTINGS: UINT = UINT(WM_APP) + 3

    /// Explorer delivers tray clicks with SendMessage, so they never appear in
    /// the GetMessage loop. Handle them here and hand the toggle back to that loop.
    nonisolated static let trayWndProc: WNDPROC = { hwnd, message, wParam, lParam in
        if message == WM_APP_OPEN_SETTINGS {
            MainActor.assumeIsolated { WinController.shared.showSettings() }
            return 0
        }
        if message == UINT(WM_TIMER), UInt(wParam) == UInt(WinHUD.timerId) {
            WinHUD.hide()
            return 0
        }
        if PenBarrel.handle(message: message, lParam: lParam) {
            return 0
        }
        if message == WM_APP_SHOW_MENU {
            MainActor.assumeIsolated { WinController.shared.showTrayMenu() }
            return 0
        }
        if message == UINT(WM_COMMAND) {
            let id = Int(wParam & 0xFFFF)
            MainActor.assumeIsolated { WinController.shared.performTrayCommand(id) }
            return 0
        }
        if message == UINT(WM_DRAWITEM) {
            if let drawItem = UnsafeMutablePointer<DRAWITEMSTRUCT>(bitPattern: UInt(bitPattern: Int(lParam))),
               let renderer = currentMenuRenderer {
                var item = drawItem.pointee
                WinTrayMenu.drawItem(&item, items: renderer.drawingItems)
            }
            return 1
        }
        if message == UINT(WM_MEASUREITEM) {
            if let measureItem = UnsafeMutablePointer<MEASUREITEMSTRUCT>(bitPattern: UInt(bitPattern: Int(lParam))),
               let renderer = currentMenuRenderer {
                var item = measureItem.pointee
                WinTrayMenu.measureItem(&item, items: renderer.drawingItems)
                measureItem.pointee = item
            }
            return 1
        }
        guard message == WM_APP_TRAY else {
            return DefWindowProcW(hwnd, message, wParam, lParam)
        }
        let event = UINT(LOWORD(lParam))
        switch event {
        case UINT(WM_LBUTTONUP), UINT(WM_LBUTTONDBLCLK), UINT(WM_USER):
            _ = PostThreadMessageW(GetCurrentThreadId(), UINT(WM_HOTKEY), 1, 0)
        case UINT(WM_RBUTTONUP), UINT(WM_CONTEXTMENU):
            _ = PostMessageW(hwnd, WM_APP_SHOW_MENU, 0, 0)
        default:
            break
        }
        return 0
    }

    nonisolated private static func registerTrayClass() {
        var windowClass = WNDCLASSEXW()
        windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        windowClass.lpfnWndProc = trayWndProc
        windowClass.hInstance = GetModuleHandleW(nil)
        let name = trayClassName.wide
        name.withUnsafeBufferPointer { buffer in
            windowClass.lpszClassName = buffer.baseAddress
            if RegisterClassExW(&windowClass) == 0 {
                WinLog.log("tray RegisterClassExW failed \(GetLastError())")
            }
        }
    }

    // MARK: Capture mode

    func toggleCaptureMode() {
        guard !annotating else {
            if canvas.hasContent {
                if config.stopAction == "clipboard" {
                    copyToClipboard()
                } else {
                    copyAndPaste()
                }
            } else {
                stopCapture()
            }
            return
        }

        // TrackPopupMenu temporarily foregrounds our tray window. Remember the
        // user's previous window before opening it instead of capturing the
        // invisible tray window when Start Annotating is selected.
        previousHwnd = (menuOpen ? menuPreviousHwnd : WinWindowTargeting.externalWindow(GetForegroundWindow()))
            ?? WinWindowTargeting.frontmostOther()
        previousWindowIdentity = previousHwnd.flatMap { WinWindowTargeting.identity(of: $0) }
        annotating = true
        overlay.isClickThrough = false
        let displayId = currentDisplayId()
        annotationDisplayId = displayId
        overlay.show(onDisplay: displayId)
        if let display = WinDisplays.all().first(where: { $0.id == displayId }) ?? WinDisplays.all().first {
            paletteBar.show(palette: config.palette, display: display, position: config.floatingPosition)
        }
        WinLog.log("Annotation on")
    }

    func stopCapture() {
        annotating = false
        paletteBar.hide()
        overlay.isClickThrough = true
        overlay.hide()
        annotationDisplayId = nil
        WinLog.log("Annotation off")
    }

    func cancelCapture() {
        // Match macOS: stopping does not discard ink; Clear is explicit.
        stopCapture()
    }

    func undo() {
        canvas.undo()
        overlay.clear()
        WinLog.log("undo")
    }

    func clear() {
        canvas.clear()
        overlay.clear()
        WinLog.log("clear")
    }

    func selectInkColour(_ index: Int) {
        var palette = config.palette
        palette.select(index)
        config.palette = palette
        config.store()
        canvas.ink = palette.current
        paletteBar.update(palette: palette)
        WinLog.log("Ink: \(palette.current.hex)")
    }

    func cycleInkColour() {
        var palette = config.palette
        palette.cycle()
        selectInkColour(palette.index)
    }

    // MARK: Copy / paste

    func copyAndPaste() {
        renderAndDeliver(paste: true)
    }

    func copyToClipboard() {
        renderAndDeliver(paste: false)
    }

    /// Synchronous on purpose. The Win32 `GetMessage` loop does not drain the
    /// Swift concurrency executor, so a `Task` queued here never runs.
    private func renderAndDeliver(paste: Bool) {
        guard !rendering else { return }
        rendering = true
        defer { rendering = false }
        var toast: String?

        guard let target = captureTarget() else {
            WinLog.log("No window to capture")
            stopCapture()
            WinHUD.show("Original window unavailable — ink kept")
            return
        }

        // Hide the chrome so BitBlt does not bake the swatches or preview ink in.
        paletteBar.hide()
        overlay.hide()
        _ = DwmFlush()

        do {
            let captured = try capturer.captureWithGeometry(rect: target.frame)
            var image = captured.image
            if config.paperTone {
                image = PaperTone.apply(to: image)
            }
            let composited = compositeInk(onto: image, origin: captured.origin, scale: captured.scale)
                .flattened()
            let png = composited.pngData()
            guard clipboard.writeNow(image: composited, png: png) else {
                stopCapture()
                WinHUD.show("Clipboard unavailable — ink kept")
                return
            }
            let saveFailed = config.saveAnnotations && history.save(png: png) == nil

            if paste {
                // The screenshot is the window under the ink. The paste
                // destination is the tray-menu choice, which may be a different window.
                let destination = pasteDestination()
                if let destination {
                    if IsIconic(destination) {
                        ShowWindow(destination, SW_RESTORE)
                    }
                    var focused = SetForegroundWindow(destination)
                    if GetForegroundWindow() != destination {
                        WinPaster.pulseAlt()
                        let flags = UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW)
                        _ = SetWindowPos(destination, HWND(bitPattern: -1), 0, 0, 0, 0, flags)
                        _ = SetWindowPos(destination, HWND(bitPattern: -2), 0, 0, 0, 0, flags)
                        focused = SetForegroundWindow(destination)
                        _ = BringWindowToTop(destination)
                    }
                    let match = GetForegroundWindow() == destination
                    WinLog.log("SetForegroundWindow paste=\(focused) match=\(match) dest=\(WinWindowTargeting.label(for: destination)) fg=\(WinWindowTargeting.label(for: GetForegroundWindow())) \(config.pasteTargetLabel)")
                    WinPaster.pump(for: 0.12)
                }
                let alt = imagePasteUsesAlt(destination)
                WinLog.log("paste chord \(alt ? "alt+v" : "ctrl+v") setting=\(config.pasteChord ?? "auto")")
                // Never send a paste chord to whichever unrelated window happens
                // to be foreground if targeting/focus failed or changed.
                let focusedDestination = destination.map { GetForegroundWindow() == $0 } ?? false
                let expectedIdentity = config.pasteOverrideHwnd != nil ? config.pasteOverrideIdentity
                    : (config.pastePreference == .previousApp ? previousWindowIdentity : nil)
                let pasted = focusedDestination && paster.pasteNow(alt: alt, destination: destination, expected: expectedIdentity)
                toast = Self.deliveryMessage(pasteSent: pasted, saveFailed: saveFailed)
                if config.pasteOverrideHwnd != nil && destination == nil {
                    toast = saveFailed ? "Copied — reselect paste window; save failed" : "Copied — reselect paste window"
                }
            } else {
                toast = Self.deliveryMessage(pasteSent: nil, saveFailed: saveFailed)
            }
        } catch {
            WinLog.log("Capture failed: \(error)")
            toast = "Capture failed"
        }

        // Preserve the annotation for another capture, matching the macOS shell.
        stopCapture()
        if let toast {
            WinHUD.show(toast)
        }
    }

    static func deliveryMessage(pasteSent: Bool?, saveFailed: Bool) -> String {
        let message = pasteSent.map { $0 ? "Copied — paste sent" : "Copied — paste failed" } ?? "Copied to clipboard"
        return saveFailed ? message + "; save failed" : message
    }

    /// Save the current annotation without stopping or pasting. Used by the
    /// floating palette's save control.
    func saveAnnotation() {
        guard !rendering else { return }
        rendering = true
        defer { rendering = false }
        guard let target = captureTarget() else {
            WinHUD.show("Original window unavailable — ink kept")
            return
        }
        paletteBar.hide()
        overlay.hide()
        _ = DwmFlush()
        var toast = "Save failed"
        do {
            let captured = try capturer.captureWithGeometry(rect: target.frame)
            var image = captured.image
            if config.paperTone {
                image = PaperTone.apply(to: image)
            }
            let composited = compositeInk(onto: image, origin: captured.origin, scale: captured.scale)
                .flattened()
            if history.save(png: composited.pngData()) != nil {
                toast = "Saved to folder"
            }
        } catch {
            WinLog.log("Save failed: \(error)")
        }
        // Restore the chrome so annotation can continue.
        let displays = WinDisplays.all()
        let restoreId = annotationDisplayId ?? currentDisplayId()
        overlay.show(onDisplay: restoreId)
        if let display = displays.first(where: { $0.id == restoreId }) ?? displays.first {
            paletteBar.show(palette: config.palette, display: display, position: config.floatingPosition)
        }
        WinHUD.show(toast)
    }

    private func compositeInk(onto image: ImageBuffer, origin: Point, scale: Double) -> ImageBuffer {
        var style = StrokeStyle.standard
        style.fixedWidth *= scale
        style.minWidth *= scale
        style.maxWidth *= scale

        let strokes = canvas.allStrokes().map { stroke in
            Stroke(
                ink: stroke.ink,
                points: stroke.points.map { point in
                    StrokePoint(
                        location: Point(
                            x: point.location.x - origin.x,
                            y: point.location.y - origin.y
                        ),
                        pressure: point.pressure,
                        isTablet: point.isTablet
                    )
                }
            )
        }
        return BufferInkCompositor().composite(strokes: strokes, style: style, onto: image)
    }

    /// The window the user was in when annotation started. After the overlay
    /// takes the foreground, GetForegroundWindow() is no longer that window.
    private func captureTarget() -> WinWindowTargeting.Target? {
        return WinWindowTargeting.rememberedCaptureTarget(previousHwnd, expected: previousWindowIdentity)
    }

    /// Where Ctrl+V is sent. A pinned window wins. Otherwise the preference
    /// is the window that was behind the ink, or the frontmost other window.
    private func pasteDestination() -> HWND? {
        if config.pasteOverrideHwnd != nil {
            return WinWindowTargeting.pinnedWindow(bits: config.pasteOverrideHwnd, expected: config.pasteOverrideIdentity)
        }
        switch config.pastePreference {
        case .frontmostApp:
            return WinWindowTargeting.frontmostOther()
        case .previousApp:
            return WinWindowTargeting.rememberedCaptureTarget(previousHwnd, expected: previousWindowIdentity)?.hwnd
        }
    }

    private func currentDisplayId() -> UInt32 {
        // The display that currently contains the cursor: annotation starts
        // where the user is working (best-effort default until a picker exists).
        var cursor = POINT()
        _ = GetCursorPos(&cursor)
        let point = Point(x: Double(cursor.x), y: Double(cursor.y))
        return WinDisplays.display(containing: point)?.id ?? WinDisplays.all().first?.id ?? 0
    }

    // MARK: Tray menu

    func showSettings() {
        if annotating { stopCapture() }
        if settingsWindow == nil {
            let window = WinSettings()
            window.onSave = { [weak self] candidate in
                guard let self else { return "App is closing." }
                return self.applySettings(candidate)
            }
            window.onMenu = { [weak self] owner in self?.showTrayMenu(owner: owner) }
            settingsWindow = window
        }
        settingsWindow?.show(config: config)
    }

    private func applySettings(_ candidate: WinConfig) -> String? {
        do {
            try FileManager.default.createDirectory(atPath: candidate.resolvedAnnotationFolder, withIntermediateDirectories: true)
        } catch { return "Cannot use that annotations folder. Choose another folder." }
        let hotkeyChanged = candidate.hotkeyCode != config.hotkeyCode || candidate.hotkeyModifiers != config.hotkeyModifiers
        func restoreHotkey() {
            _ = UnregisterHotKey(nil, 1)
            registerHotkey()
        }
        if hotkeyChanged {
            _ = UnregisterHotKey(nil, 1)
            if !RegisterHotKey(nil, 1, UINT(candidate.hotkeyModifiers) | UINT(MOD_NOREPEAT), UINT(candidate.hotkeyCode)) {
                restoreHotkey()
                return "That shortcut is unavailable. Choose another shortcut."
            }
        }
        guard candidate.store() else {
            if hotkeyChanged { restoreHotkey() }
            return "Settings could not be saved. Your previous settings are still active."
        }
        config = candidate
        Self.hotkeyStatus = "OK (\(config.hotkeyDisplay))"
        canvas.ink = config.palette.current
        history.setFolder(config.resolvedAnnotationFolder)
        paletteBar.update(palette: config.palette)
        return nil
    }

    private var menuWindows: [WinWindowTargeting.ListedWindow] = []
    private var menuHistoryFiles: [URL] = []
    private var menuOpen = false
    private var menuPreviousHwnd: HWND?

    /// Right-click menu. Left-click still toggles annotation.
    func showTrayMenu(owner: HWND? = nil) {
        guard !menuOpen else { return }
        menuOpen = true
        menuPreviousHwnd = WinWindowTargeting.externalWindow(GetForegroundWindow()) ?? WinWindowTargeting.frontmostOther()
        defer {
            menuPreviousHwnd = nil
            menuOpen = false
        }
        let menuOwner = owner ?? Self.trayWindow

        // Build the item tree for the owner-draw menu renderer.
        var items: [WinTrayMenu.Item] = []

        // Top-level: toggle annotation
        let toggleTitle = canvas.hasContent && annotating ? (config.stopAction == "clipboard" ? "Stop & Copy" : "Stop & Paste") : (annotating ? "Stop Annotating" : "Start Annotating")
        items.append(WinTrayMenu.Item(id: WinTrayCommand.toggle, title: toggleTitle, checked: false, enabled: true))

        // Colour palette with swatches, add/remove
        var colourItems: [WinTrayMenu.Item] = []
        for (index, color) in config.palette.colors.prefix(64).enumerated() {
            colourItems.append(WinTrayMenu.Item(
                id: WinTrayCommand.colourBase + index,
                title: config.displayName(for: color),
                checked: index == config.palette.index,
                enabled: true,
                swatchColor: color
            ))
        }
        if config.palette.colors.count > 64 {
            colourItems.append(WinTrayMenu.Item(id: WinTrayCommand.settings, title: "More colours…"))
        }
        colourItems.append(WinTrayMenu.Item(id: 0, title: "", checked: false, enabled: false, isSeparator: true))
        // Add colour
        var addItems: [WinTrayMenu.Item] = []
        for (index, extra) in WinColourNames.extras(current: config.palette.colors).enumerated() {
            addItems.append(WinTrayMenu.Item(id: WinTrayCommand.addColourBase + index, title: WinColourNames.name(for: extra), checked: false, enabled: true, swatchColor: extra))
        }
        let addMenu = WinTrayMenu(items: addItems, onSelect: { [weak self] id in self?.performTrayCommand(id) })
        colourItems.append(WinTrayMenu.Item(id: 0, title: "Add colour", checked: false, enabled: true, isSubmenu: true, submenu: addMenu))
        // Remove colour
        var removeItems: [WinTrayMenu.Item] = []
        for (index, color) in config.palette.colors.prefix(64).enumerated() where config.palette.customIndices.contains(index) {
            removeItems.append(WinTrayMenu.Item(id: WinTrayCommand.removeColourBase + index, title: "Remove \(config.displayName(for: color))", checked: false, enabled: true, swatchColor: color))
        }
        let removeMenu = WinTrayMenu(items: removeItems, onSelect: { [weak self] id in self?.performTrayCommand(id) })
        colourItems.append(WinTrayMenu.Item(id: 0, title: "Remove colour", checked: false, enabled: !removeItems.isEmpty, isSubmenu: true, submenu: removeMenu))
        let colourMenu = WinTrayMenu(items: colourItems, onSelect: { [weak self] id in self?.performTrayCommand(id) })
        items.append(WinTrayMenu.Item(id: 0, title: "Ink Colour (\(config.displayName(for: config.palette.current)))", checked: false, enabled: true, isSubmenu: true, submenu: colourMenu))

        // Stop action submenu (radio group)
        let stopMenu = WinTrayMenu(items: [
            WinTrayMenu.Item(id: WinTrayCommand.stopClipboard, title: "Copy to clipboard", checked: config.stopAction == "clipboard", enabled: true),
            WinTrayMenu.Item(id: WinTrayCommand.stopCopyAndPaste, title: "Copy and paste", checked: config.stopAction != "clipboard", enabled: true)
        ], onSelect: { [weak self] id in self?.performTrayCommand(id) })
        items.append(WinTrayMenu.Item(id: 0, title: "On stop", checked: false, enabled: true, isSubmenu: true, submenu: stopMenu))

        // Paste into (with window list)
        let unpinned = config.pasteOverrideHwnd == nil
        var pasteItems: [WinTrayMenu.Item] = [
            WinTrayMenu.Item(id: WinTrayCommand.pastePrevious, title: "Previous window", checked: unpinned && config.pastePreference == .previousApp, enabled: true),
            WinTrayMenu.Item(id: WinTrayCommand.pasteFrontmost, title: "Frontmost window", checked: unpinned && config.pastePreference == .frontmostApp, enabled: true),
            WinTrayMenu.Item(id: 0, title: "", checked: false, enabled: false, isSeparator: true)
        ]
        let windows = WinWindowTargeting.visibleWindows()
        menuWindows = Array(windows.prefix(WinTrayCommand.windowLimit))
        if menuWindows.isEmpty {
            pasteItems.append(WinTrayMenu.Item(id: 0, title: "No other windows running", checked: false, enabled: false))
        } else {
            let titles = Dictionary(grouping: menuWindows, by: \.title)
            for (index, window) in menuWindows.enumerated() {
                let duplicate = (titles[window.title]?.count ?? 0) > 1
                let pinned = config.pasteOverrideHwnd == WinWindowTargeting.bits(window.hwnd)
                    && WinWindowTargeting.identityMatches(expected: config.pasteOverrideIdentity, observed: window.identity)
                pasteItems.append(WinTrayMenu.Item(
                    id: WinTrayCommand.windowBase + index,
                    title: window.label(duplicate: duplicate),
                    checked: pinned,
                    enabled: true
                ))
            }
        }
        let pasteMenu = WinTrayMenu(items: pasteItems, onSelect: { [weak self] id in self?.performTrayCommand(id) })
        let pinInvalid = config.pasteOverrideHwnd != nil && WinWindowTargeting.pinnedWindow(bits: config.pasteOverrideHwnd, expected: config.pasteOverrideIdentity) == nil
        let targetLabel = config.pasteTargetLabel + (pinInvalid ? " — reselect" : "")
        items.append(WinTrayMenu.Item(id: 0, title: "Paste into (\(targetLabel))", checked: false, enabled: true, isSubmenu: true, submenu: pasteMenu))

        // History
        let files = Array(history.files().prefix(10))
        menuHistoryFiles = files
        var historyItems: [WinTrayMenu.Item] = []
        if files.isEmpty {
            historyItems.append(WinTrayMenu.Item(id: 0, title: "No saved annotations", checked: false, enabled: false))
        } else {
            for (index, url) in files.enumerated() {
                let name = url.lastPathComponent
                historyItems.append(WinTrayMenu.Item(id: WinTrayCommand.historyBase + index, title: name, checked: false, enabled: true))
            }
        }
        historyItems.append(WinTrayMenu.Item(id: 0, title: "", checked: false, enabled: false, isSeparator: true))
        historyItems.append(WinTrayMenu.Item(id: WinTrayCommand.historyOpenFolder, title: "Open Annotations Folder", checked: false, enabled: true))
        let historyMenu = WinTrayMenu(items: historyItems, onSelect: { [weak self] id in self?.performTrayCommand(id) })
        items.append(WinTrayMenu.Item(id: 0, title: "History", checked: false, enabled: true, isSubmenu: true, submenu: historyMenu))

        items.append(WinTrayMenu.Item(id: WinTrayCommand.clear, title: "Clear", checked: false, enabled: canvas.hasContent))

        // Paste chord submenu (radio group)
        let chordMenu = WinTrayMenu(items: [
            WinTrayMenu.Item(id: WinTrayCommand.pasteChordAuto, title: "Paste keys: Automatic", checked: config.pasteChord != "ctrlV" && config.pasteChord != "altV", enabled: true),
            WinTrayMenu.Item(id: WinTrayCommand.pasteChordCtrlV, title: "Paste keys: Ctrl+V", checked: config.pasteChord == "ctrlV", enabled: true),
            WinTrayMenu.Item(id: WinTrayCommand.pasteChordAltV, title: "Paste keys: Alt+V", checked: config.pasteChord == "altV", enabled: true)
        ], onSelect: { [weak self] id in self?.performTrayCommand(id) })
        items.append(WinTrayMenu.Item(id: 0, title: "Paste keys…", checked: false, enabled: true, isSubmenu: true, submenu: chordMenu))


        // Floating palette position
        var posItems: [WinTrayMenu.Item] = []
        for (index, pos) in WinFloatingPosition.allCases.enumerated() {
            posItems.append(WinTrayMenu.Item(id: WinTrayCommand.posBase + index, title: pos.title, checked: config.floatingPosition == pos, enabled: true))
        }
        let posMenu = WinTrayMenu(items: posItems, onSelect: { [weak self] id in self?.performTrayCommand(id) })
        items.append(WinTrayMenu.Item(id: 0, title: "Floating Palette", checked: false, enabled: true, isSubmenu: true, submenu: posMenu))

        // Paper tone toggle
        items.append(WinTrayMenu.Item(id: WinTrayCommand.paperTone, title: "Soften white backgrounds", checked: config.paperTone, enabled: true))

        // Save annotations toggle
        items.append(WinTrayMenu.Item(id: WinTrayCommand.saveAnnotations, title: "Save annotations", checked: config.saveAnnotations, enabled: true))

        // Autostart toggle
        items.append(WinTrayMenu.Item(id: WinTrayCommand.autostart, title: "Launch at login", checked: WinAutostart.isEnabled(), enabled: true))

        items.append(WinTrayMenu.Item(id: WinTrayCommand.settings, title: "Settings…", enabled: true))
        items.append(WinTrayMenu.Item(id: WinTrayCommand.permissions, title: "Check Permissions", checked: false, enabled: true))

        items.append(WinTrayMenu.Item(id: 0, title: "", checked: false, enabled: false, isSeparator: true))
        items.append(WinTrayMenu.Item(id: 0, title: config.hotkeyDisplay, checked: false, enabled: false, isSectionHeader: true))
        items.append(WinTrayMenu.Item(id: 0, title: "", checked: false, enabled: false, isSeparator: true))
        items.append(WinTrayMenu.Item(id: WinTrayCommand.quit, title: "Quit ScribbleEverywhere", checked: false, enabled: true))

        // Build the owner-draw menu
        let renderer = WinTrayMenu(items: items, onSelect: { [weak self] id in self?.performTrayCommand(id) })
        Self.currentMenuRenderer = renderer
        guard let menu = renderer.buildMenu() else {
            WinLog.log("CreatePopupMenu failed \(GetLastError())")
            Self.currentMenuRenderer = nil
            return
        }
        defer {
            _ = DestroyMenu(menu)
            Self.currentMenuRenderer = nil
        }

        var point = POINT()
        _ = GetCursorPos(&point)
        _ = SetForegroundWindow(menuOwner)
        WinLog.log("tray menu at \(point.x),\(point.y) items=\(items.count)")
        _ = TrackPopupMenu(
            menu,
            WinTrayCommand.rightAlign | WinTrayCommand.bottomAlign,
            point.x,
            point.y,
            0,
            menuOwner,
            nil
        )
        _ = PostMessageW(menuOwner, UINT(WM_NULL), 0, 0)
    }

    func performTrayCommand(_ id: Int) {
        guard id != 0 else { return }
        WinLog.log("tray command \(id)")
        switch id {
        case WinTrayCommand.settings:
            showSettings()
        case WinTrayCommand.toggle:
            toggleCaptureMode()
        case WinTrayCommand.clear:
            clear()
        case WinTrayCommand.quit:
            if var data = notificationIconData {
                _ = Shell_NotifyIconW(UINT(NIM_DELETE), &data)
            }
            PostQuitMessage(0)
        case WinTrayCommand.pastePrevious:
            setPastePreference(.previousApp)
        case WinTrayCommand.pasteFrontmost:
            setPastePreference(.frontmostApp)
        case WinTrayCommand.stopCopyAndPaste:
            config.stopAction = "copyAndPaste"
            config.store()
        case WinTrayCommand.stopClipboard:
            config.stopAction = "clipboard"
            config.store()
        case WinTrayCommand.pasteChordAuto:
            config.pasteChord = "auto"
            config.store()
        case WinTrayCommand.pasteChordCtrlV:
            config.pasteChord = "ctrlV"
            config.store()
        case WinTrayCommand.pasteChordAltV:
            config.pasteChord = "altV"
            config.store()
        case WinTrayCommand.colourBase..<(WinTrayCommand.colourBase + 64):
            selectInkColour(id - WinTrayCommand.colourBase)
        case WinTrayCommand.paperTone:
            config.paperTone.toggle()
            config.store()
            WinLog.log("paper tone \(config.paperTone)")
        case WinTrayCommand.saveAnnotations:
            config.saveAnnotations.toggle()
            config.store()
            WinLog.log("save annotations \(config.saveAnnotations)")
        case WinTrayCommand.autostart:
            let enable = !WinAutostart.isEnabled()
            if WinAutostart.setEnabled(enable) {
                config.launchOnStartup = enable
                config.store()
                WinLog.log("autostart \(enable)")
            } else {
                WinHUD.show("Launch at login update failed")
            }
        case WinTrayCommand.permissions:
            let report = WinDiagnostics.run(annotationFolder: config.resolvedAnnotationFolder)
            WinLog.log("permissions:\n\(report)")
            _ = MessageBoxW(Self.trayWindow, report.wide, "ScribbleEverywhere diagnostics".wide, UINT(MB_OK | MB_ICONINFORMATION))
        case WinTrayCommand.historyOpenFolder:
            history.reveal(nil)
        case WinTrayCommand.historyBase..<(WinTrayCommand.historyBase + 10):
            let index = id - WinTrayCommand.historyBase
            guard menuHistoryFiles.indices.contains(index) else { return }
            history.reveal(menuHistoryFiles[index])
        case WinTrayCommand.addColourBase..<(WinTrayCommand.addColourBase + 32):
            let index = id - WinTrayCommand.addColourBase
            let extras = WinColourNames.extras(current: config.palette.colors)
            guard extras.indices.contains(index) else { return }
            var palette = config.palette
            palette.add(extras[index])
            config.palette = palette
            config.store()
            canvas.ink = palette.current
            WinLog.log("palette add \(extras[index].hex)")
        case WinTrayCommand.removeColourBase..<(WinTrayCommand.removeColourBase + 64):
            let index = id - WinTrayCommand.removeColourBase
            var palette = config.palette
            guard palette.customIndices.contains(index) else { return }
            let removed = palette.colors[index]
            palette.remove(at: index)
            config.palette = palette
            if !palette.colors.contains(removed) {
                config.colourNames.removeValue(forKey: removed.hex)
            }
            config.store()
            canvas.ink = palette.current
            WinLog.log("palette remove \(removed.hex)")
        case WinTrayCommand.posBase..<(WinTrayCommand.posBase + 8):
            let index = id - WinTrayCommand.posBase
            guard WinFloatingPosition.allCases.indices.contains(index) else { return }
            let position = WinFloatingPosition.allCases[index]
            config.floatingPalettePosition = position.rawValue
            config.store()
            WinLog.log("palette position \(position.rawValue)")
        case WinTrayCommand.windowBase..<(WinTrayCommand.windowBase + WinTrayCommand.windowLimit):
            let index = id - WinTrayCommand.windowBase
            guard menuWindows.indices.contains(index) else { return }
            let window = menuWindows[index]
            guard WinWindowTargeting.identity(of: window.hwnd) == window.identity else {
                WinHUD.show("Window changed — select it again")
                return
            }
            config.pasteOverrideHwnd = WinWindowTargeting.bits(window.hwnd)
            config.pasteOverrideTitle = window.label(duplicate: false)
            config.pasteOverrideIdentity = window.identity
            config.store()
            WinLog.log("paste target \(config.pasteOverrideTitle ?? "")")
        default:
            break
        }
    }

    /// Automatic follows the destination. Windows Terminal swallows Ctrl+V
    /// when the clipboard is a picture, and Grok reads that picture on Alt+V.
    private func imagePasteUsesAlt(_ destination: HWND?) -> Bool {
        switch config.pasteChord {
        case "ctrlV":
            return false
        case "altV":
            return true
        default:
            guard let destination else { return false }
            return WinWindowTargeting.prefersAltImagePaste(destination)
        }
    }

    private func setPastePreference(_ preference: PasteTargetPreference) {
        config.pasteTarget = preference.rawValue
        config.pasteOverrideHwnd = nil
        config.pasteOverrideTitle = nil
        config.pasteOverrideIdentity = nil
        config.store()
        WinLog.log("paste target \(preference.rawValue)")
    }

}

/// Command ids for the tray menu. Window ids are `windowBase + index` into
/// the list captured when the menu opened.
enum WinTrayCommand {
    static let settings = 1010
    static let toggle = 1001
    static let clear = 1002
    static let quit = 1003
    static let stopCopyAndPaste = 1103
    static let stopClipboard = 1104
    static let pasteChordAuto = 1105
    static let pasteChordCtrlV = 1106
    static let pasteChordAltV = 1107
    static let pastePrevious = 1101
    static let pasteFrontmost = 1102
    static let paperTone = 1301
    static let saveAnnotations = 1302
    static let autostart = 1303
    static let permissions = 1304
    static let historyOpenFolder = 1305
    static let colourBase = 1400
    static let addColourBase = 1500
    static let removeColourBase = 1600
    static let posBase = 1700
    static let historyBase = 1800
    static let windowBase = 2000
    static let windowLimit = 40
    static let string: UINT = 0x0000
    static let grayed: UINT = 0x0001
    static let checked: UINT = 0x0008
    static let popup: UINT = 0x0010
    static let separator: UINT = 0x0800
    static let rightAlign: UINT = 0x0008
    static let bottomAlign: UINT = 0x0020
}

// MARK: - Entry point and message loop

@main
struct PalimpsestWinApp {
    static func main() {
        if CommandLine.arguments.contains("/validation-canvas") {
            enablePerMonitorV2()
            MainActor.assumeIsolated { WinValidationCanvas.run() }
            return
        }
        let isolated = CommandLine.arguments.contains("/validation-isolated")
        var validationDirectory: URL?
        defer {
            if let validationDirectory { try? FileManager.default.removeItem(at: validationDirectory) }
        }
        if isolated {
            // A disposable, opt-in instance can be tested alongside the real
            // tray app without reading or rewriting its settings or hooks.
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("PalimpsestValidation-\(UUID().uuidString)", isDirectory: true)
            validationDirectory = directory
            guard SetEnvironmentVariableW("APPDATA".wide, directory.path.wide),
                  SetEnvironmentVariableW("LOCALAPPDATA".wide, directory.path.wide) else { return }
            var config = WinConfig()
            config.annotationFolder = directory.appendingPathComponent("annotations").path
            config.saveAnnotations = false
            guard config.store() else { return }
            WinPenShortcut.openOnLaunch = true
        } else if !WinPenShortcut.becomePrimary() {
            return
        }
        enablePerMonitorV2()
        WinOverlay.registerClass()
        WinFloatingPalette.registerClass()
        WinHUD.registerClass()
        MainActor.assumeIsolated {
            WinController.isolatedValidation = isolated
            WinOverlay.validationWindow = isolated || CommandLine.arguments.contains("/validate-input")
            WinController.shared.start()
        }
        runMessageLoop()
    }

    /// `DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2` is `(DPI_AWARENESS_CONTEXT)-4`.
    /// The WinSDK import does not surface the macro. A Surface Book is typically
    /// 200% scaled; without this, pen points and BitBlt disagree.
    private static func enablePerMonitorV2() {
        let context = DPI_AWARENESS_CONTEXT(bitPattern: -4)
        let ok = SetProcessDpiAwarenessContext(context)
        WinLog.log("SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)=\(ok)")
    }

    private static func runMessageLoop() {
        var message = MSG()
        while GetMessageW(&message, nil, 0, 0) {
            if WinSettings.filterMessage(&message) { continue }
            _ = TranslateMessage(&message)
            _ = DispatchMessageW(&message)

            // Global hotkey arrives as WM_HOTKEY on the thread queue.
            if UINT(message.message) == UINT(WM_HOTKEY) {
                WinLog.log("WM_HOTKEY \(message.wParam)")
                MainActor.assumeIsolated {
                    switch Int(message.wParam) {
                    case 1:
                        WinController.shared.toggleCaptureMode()
                    case SurfacePenButton.hotkeyId:
                        // One physical click can launch single-click and double-click.
                        if SurfacePenButton.takeToggle() {
                            WinController.shared.toggleCaptureMode()
                        } else {
                            WinLog.log("pen toggle ignored (repeat)")
                        }
                    case 2:
                        WinController.shared.cycleInkColour()
                    default:
                        break
                    }
                }
            }

        }
    }
}

/// Surface pen tail button. One click arrives as VK_F20 (often with the Win
/// key). Screen Sketch is bound to that chord. A low-level hook sees it before
/// `RegisterHotKey` consumers, so eating F20 stops Sketch and toggles annotation.
enum SurfacePenButton {
    static let hotkeyId = 3
    private static let vkF20: UInt32 = 0x83
    private static let vkLWin: UInt32 = 0x5B
    private static let vkRWin: UInt32 = 0x5C
    private static let keyUpFlag: UInt32 = 0x80
    private static let whKeyboardLL: Int32 = 13
    private static let whMouseLL: Int32 = 14
    private static let wmRButtonDown = WPARAM(0x0204)
    private static let wmRButtonUp = WPARAM(0x0205)

    nonisolated(unsafe) private static var hook: HHOOK?
    nonisolated(unsafe) private static var mouseHook: HHOOK?
    nonisolated(unsafe) private static var suppressWinUp = false
    nonisolated(unsafe) private static var lastDown: DWORD = 0
    nonisolated(unsafe) private static var lastTip: DWORD = 0
    nonisolated(unsafe) private static var lastToggle: DWORD = 0

    static func install() {
        hook = SetWindowsHookExW(whKeyboardLL, surfacePenHook, GetModuleHandleW(nil), 0)
        if hook != nil {
            WinLog.log("pen button hook ok=true (Win+F20 toggles, Screen Sketch swallowed)")
        } else {
            let err = GetLastError()
            let modifiers = UINT(0x0008 | 0x4000) // MOD_WIN | MOD_NOREPEAT
            let registered = RegisterHotKey(nil, Int32(hotkeyId), modifiers, UINT(vkF20))
            WinLog.log("pen button hook ok=false err=\(err); RegisterHotKey Win+F20 ok=\(registered) err=\(GetLastError())")
        }
        // WH_MOUSE_LL. The barrel button is delivered as a pen right-click.
        mouseHook = SetWindowsHookExW(whMouseLL, surfacePenMouseHook, GetModuleHandleW(nil), 0)
        if mouseHook != nil {
            WinLog.log("pen tip button hook ok=true")
        } else {
            WinLog.log("pen tip button hook ok=false err=\(GetLastError())")
        }
    }

    /// Collapses the single-click and double-click launches of one press.
    static func takeToggle() -> Bool {
        let now = GetTickCount()
        let window = max(DWORD(GetDoubleClickTime()), 200)
        if now &- lastToggle < window { return false }
        lastToggle = now
        return true
    }

    /// Barrel press, from the mouse hook or from a pointer event on the overlay.
    /// Presses within 200ms count as one click.
    static func noteTipPress(_ source: String) {
        let now = GetTickCount()
        let elapsed = now &- lastTip
        lastTip = now
        guard elapsed > 200 else { return }
        WinLog.log("pen tip button (\(source))")
        _ = PostThreadMessageW(GetCurrentThreadId(), UINT(WM_HOTKEY), WPARAM(UInt(hotkeyId)), 0)
    }

    fileprivate static func handle(code: Int32, wParam: WPARAM, lParam: LPARAM) -> LRESULT {
        if code >= 0, let raw = UnsafeRawPointer(bitPattern: UInt(bitPattern: Int(lParam))) {
            let vk = raw.load(as: UInt32.self)
            let flags = raw.load(fromByteOffset: 8, as: UInt32.self)
            let up = flags & keyUpFlag != 0
            if vk == vkLWin || vk == vkRWin {
                // F20 was eaten, so Windows would treat the matching Win key-up
                // as an empty Win tap and open the Start menu.
                if up && suppressWinUp && GetTickCount() &- lastDown < 800 {
                    suppressWinUp = false
                    return 1
                }
                suppressWinUp = false
            } else if vk == vkF20 {
                if !up {
                    let now = GetTickCount()
                    let elapsed = now &- lastDown
                    lastDown = now
                    suppressWinUp = true
                    if elapsed > 200 {
                        WinLog.log("pen button F20")
                        _ = PostThreadMessageW(
                            GetCurrentThreadId(),
                            UINT(WM_HOTKEY),
                            WPARAM(UInt(hotkeyId)),
                            0
                        )
                    }
                }
                return 1
            }
        }
        return CallNextHookEx(hook, code, wParam, lParam)
    }

    /// `MSLLHOOKSTRUCT.dwExtraInfo` is at byte 24 on x64. Pen input uses
    /// signature 0xFF515700; touch sets the 0x80 bit in the low byte.
    fileprivate static func handleMouse(code: Int32, wParam: WPARAM, lParam: LPARAM) -> LRESULT {
        if code >= 0,
           wParam == wmRButtonDown || wParam == wmRButtonUp,
           let raw = UnsafeRawPointer(bitPattern: UInt(bitPattern: Int(lParam))) {
            let extra = UInt32(truncatingIfNeeded: raw.load(fromByteOffset: 24, as: UInt.self))
            let fromPen = (extra & 0xFFFFFF00) == 0xFF515700 && (extra & 0x80) == 0
            if fromPen {
                if wParam == wmRButtonDown {
                    noteTipPress(String(format: "right-click %08X", extra))
                }
                return 1
            }
        }
        return CallNextHookEx(mouseHook, code, wParam, lParam)
    }
}

private func surfacePenHook(code: Int32, wParam: WPARAM, lParam: LPARAM) -> LRESULT {
    SurfacePenButton.handle(code: code, wParam: wParam, lParam: lParam)
}

private func surfacePenMouseHook(code: Int32, wParam: WPARAM, lParam: LPARAM) -> LRESULT {
    SurfacePenButton.handleMouse(code: code, wParam: wParam, lParam: lParam)
}

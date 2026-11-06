import Foundation
import Glibc
import PalimpsestCore
import CPalimpsestLinux

private func waylandEvent(_ event: UnsafePointer<palimpsest_event>?, _ userdata: UnsafeMutableRawPointer?) {
    guard let event, let userdata else { return }
    Unmanaged<LinuxDaemon>.fromOpaque(userdata).takeUnretainedValue().handle(event.pointee)
}

private var linuxShouldQuit: Int32 = 0

private let linuxSignalHandler: @convention(c) (Int32) -> Void = { _ in
    linuxShouldQuit = 1
}

/// Wayland overlay daemon. One thread owns the compositor connection, the
/// stroke model, and the control socket. C callbacks arrive on that thread.
final class LinuxDaemon {
    private var session: UnsafeMutableRawPointer?
    let canvas: StrokeCanvas
    private var config: LinuxConfig
    private var persistedConfig: LinuxConfig
    private let configPath: String
    private var configWriteFailed = false
    private let clipboard = LinuxClipboard()
    private let paster = LinuxPaster()

    private(set) var annotating = false
    private var rendering = false
    private var previousAddress: String?
    private var dirty = false
    private var pending: [Action] = []

    private var pointerDown = false
    private var penProximity = false
    private var tipDown = false
    private var strokeOpen = false
    private var strokeIsTablet = false
    private var activeTouch: Int32?
    private var activeTouchOutput: Int32 = -1
    private var ctrlKeys: Set<UInt32> = []
    private var lastPoint = Point(x: 0, y: 0)
    private var tabletPressure = 0.5
    private var lastContactPressure = 0.5
    private var lastToggleAt = Date.distantPast
    private var paletteHold = false
    private var lockFD: Int32 = -1
    private let stylusMonitor = StylusEvdevMonitor()

    private var controlFD: Int32 = -1
    private var clients: [Client] = []

    private enum Action {
        case toggle, copy, paste, undo, clear, cycle, cancel
    }

    private final class Client {
        let fd: Int32
        var buffer = Data()
        init(fd: Int32) { self.fd = fd }
    }

    /// Documented Hyprland chord. Not read from hyprland.conf.
    static let documentedHotkey = "Super+Alt+D"

    init(config: LinuxConfig = .load(), canvas: StrokeCanvas = StrokeCanvas(), configPath: String = LinuxConfig.path()) {
        self.config = config
        self.persistedConfig = config
        self.configPath = configPath
        self.canvas = canvas
    }

    static var socketPath: String {
        let dir = env("XDG_RUNTIME_DIR") ?? "/tmp"
        return "\(dir)/palimpsest-ink.sock"
    }

    var socketPath: String { Self.socketPath }

    // MARK: Lifecycle

    /// Returns false when another daemon holds the lock or Wayland is unavailable.
    func connect() -> Bool {
        guard takeLock() else {
            LinuxLog.log("Another palimpsest-ink daemon is already running")
            return false
        }
        signal(SIGINT, linuxSignalHandler)
        signal(SIGTERM, linuxSignalHandler)
        signal(SIGPIPE, SIG_IGN)

        var raw: UnsafeMutableRawPointer?
        var error = [CChar](repeating: 0, count: 512)
        let userdata = Unmanaged.passUnretained(self).toOpaque()
        let connected = error.withUnsafeMutableBufferPointer { buffer -> Int32 in
            palimpsest_wl_connect(&raw, waylandEvent, userdata, buffer.baseAddress, buffer.count)
        }
        guard connected == 0, let raw else {
            let message = String(cString: error)
            LinuxLog.log(message.isEmpty ? "Wayland connect failed" : message)
            return false
        }
        session = raw
        canvas.ink = config.palette.current
        openControlSocket()
        stylusMonitor.openIfNeeded(force: true)
        let outputs = outputInfos()
        LinuxLog.log("Daemon ready, \(outputs.count) output(s), ink \(canvas.ink.hex)")
        for info in outputs {
            LinuxLog.log("output \(info.id) origin \(info.x),\(info.y) scale \(info.scale) mode-logical pending")
        }
        return true
    }

    func run() {
        guard session != nil else { return }
        while linuxShouldQuit == 0 {
            stylusMonitor.openIfNeeded()
            var fds: [Int32] = []
            if controlFD >= 0 { fds.append(controlFD) }
            for client in clients { fds.append(client.fd) }
            if stylusMonitor.fd >= 0 { fds.append(stylusMonitor.fd) }
            var ready = [Int32](repeating: 0, count: max(fds.count, 1))
            let timeout: Int32 = (dirty || !pending.isEmpty) ? 16 : 200
            let rc = fds.withUnsafeBufferPointer { fdPointer -> Int32 in
                ready.withUnsafeMutableBufferPointer { readyPointer in
                    palimpsest_wl_poll(
                        session, fdPointer.baseAddress, Int32(fds.count),
                        readyPointer.baseAddress, timeout
                    )
                }
            }
            if rc < 0 {
                LinuxLog.log("Wayland connection closed")
                break
            }
            for (index, fd) in fds.enumerated() where index < ready.count && ready[index] != 0 {
                if fd == stylusMonitor.fd {
                    if stylusMonitor.consumePress(), !annotating {
                        pending.append(.toggle)
                    }
                } else if fd == controlFD {
                    acceptClient()
                } else {
                    readClient(fd: fd)
                }
            }
            if dirty {
                dirty = false
                redrawAll()
            }
            drainActions()
        }
        shutdown()
    }

    private func shutdown() {
        if let session {
            palimpsest_wl_hide(session)
            palimpsest_wl_destroy(session)
            self.session = nil
        }
        for client in clients { close(client.fd) }
        clients.removeAll()
        if controlFD >= 0 {
            close(controlFD)
            unlink(socketPath)
            controlFD = -1
        }
        if lockFD >= 0 {
            close(lockFD)
            lockFD = -1
        }
        stylusMonitor.close()
    }

    private func takeLock() -> Bool {
        let path = ((socketPath as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("palimpsest-ink.lock")
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else {
            LinuxLog.log("Could not open \(path)")
            return false
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        lockFD = fd
        return true
    }

    // MARK: Input

    func handle(_ event: palimpsest_event) {
        switch Int(event.kind) {
        case PALIMPSEST_EVENT_POINTER_ENTER, PALIMPSEST_EVENT_POINTER_MOTION:
            guard activeTouch == nil, !penProximity else { return }
            lastPoint = globalPoint(outputID: event.output_id, x: event.x, y: event.y)
            if pointerDown && !penProximity && !paletteHold {
                extend(at: lastPoint, pressure: 0.5, isTablet: false)
            }
        case PALIMPSEST_EVENT_POINTER_LEAVE:
            if pointerDown && !penProximity {
                pointerDown = false
                paletteHold = false
                end(at: lastPoint, pressure: 0.5, isTablet: false)
            }
        case PALIMPSEST_EVENT_POINTER_BUTTON:
            guard activeTouch == nil else { return }
            lastPoint = globalPoint(outputID: event.output_id, x: event.x, y: event.y)
            if event.pressed == 1 {
                LinuxLog.log(String(format: "pointer button code=0x%X pen=%d", event.code, penProximity ? 1 : 0))
            }
            if event.code == 0x111 && event.pressed == 1 {
                // Barrel is pointer-emulated as RMB while the overlay has
                // tablet focus. A real mouse RMB still cycles colour.
                pending.append(penProximity ? .toggle : .cycle)
                return
            }
            guard !penProximity else { return }
            guard event.code == 0x110 else { return }
            if event.pressed == 1 {
                if consumePaletteHit(outputID: event.output_id, x: event.x, y: event.y) {
                    paletteHold = true
                    return
                }
                pointerDown = true
                begin(at: lastPoint, pressure: 0.5, isTablet: false)
            } else if paletteHold {
                paletteHold = false
            } else if pointerDown {
                pointerDown = false
                end(at: lastPoint, pressure: 0.5, isTablet: false)
            }
        case PALIMPSEST_EVENT_TOUCH_DOWN:
            guard !penProximity, activeTouch == nil, !pointerDown, !strokeOpen else { return }
            activeTouch = event.touch_id
            activeTouchOutput = event.output_id
            lastPoint = globalPoint(outputID: event.output_id, x: event.x, y: event.y)
            if consumePaletteHit(outputID: event.output_id, x: event.x, y: event.y) {
                paletteHold = true
                return
            }
            begin(at: lastPoint, pressure: 0.5, isTablet: false)
        case PALIMPSEST_EVENT_TOUCH_MOTION:
            guard event.touch_id == activeTouch else { return }
            lastPoint = globalPoint(outputID: activeTouchOutput, x: event.x, y: event.y)
            if !paletteHold {
                extend(at: lastPoint, pressure: 0.5, isTablet: false)
            }
        case PALIMPSEST_EVENT_TOUCH_UP:
            guard event.touch_id == activeTouch else { return }
            activeTouch = nil
            if paletteHold {
                paletteHold = false
                return
            }
            end(at: lastPoint, pressure: 0.5, isTablet: false)
        case PALIMPSEST_EVENT_TOUCH_CANCEL:
            guard activeTouch != nil else { return }
            activeTouch = nil
            paletteHold = false
            if strokeOpen && !strokeIsTablet {
                if canvas.current != nil { canvas.undo() }
                strokeOpen = false
                dirty = true
            }
        case PALIMPSEST_EVENT_TABLET_PROXIMITY:
            penProximity = event.pressed == 1
            if !penProximity && strokeOpen && strokeIsTablet {
                tipDown = false
                end(at: lastPoint, pressure: lastContactPressure, isTablet: true)
            }
            if penProximity && (pointerDown || activeTouch != nil) {
                let rejectedTouch = activeTouch != nil
                pointerDown = false
                activeTouch = nil
                paletteHold = false
                if strokeOpen && !strokeIsTablet {
                    if rejectedTouch {
                        if canvas.current != nil { canvas.undo() }
                        strokeOpen = false
                        dirty = true
                    } else {
                        end(at: lastPoint, pressure: 0.5, isTablet: false)
                    }
                }
            }
        case PALIMPSEST_EVENT_TABLET_MOTION:
            lastPoint = globalPoint(outputID: event.output_id, x: event.x, y: event.y)
        case PALIMPSEST_EVENT_TABLET_PRESSURE:
            tabletPressure = event.pressure
        case PALIMPSEST_EVENT_TABLET_DOWN:
            tipDown = true
        case PALIMPSEST_EVENT_TABLET_UP:
            tipDown = false
        case PALIMPSEST_EVENT_TABLET_FRAME:
            guard penProximity || tipDown || paletteHold || (strokeOpen && strokeIsTablet) else { return }
            if event.output_id >= 0 {
                lastPoint = globalPoint(outputID: event.output_id, x: event.x, y: event.y)
            }
            if paletteHold && !tipDown {
                paletteHold = false
                return
            }
            if paletteHold {
                return
            }
            if tipDown {
                lastContactPressure = tabletPressure
                if strokeOpen && strokeIsTablet {
                    extend(at: lastPoint, pressure: tabletPressure, isTablet: true)
                } else if !strokeOpen {
                    if event.output_id >= 0,
                       consumePaletteHit(outputID: event.output_id, x: event.x, y: event.y) {
                        paletteHold = true
                        return
                    }
                    begin(at: lastPoint, pressure: tabletPressure, isTablet: true)
                }
            } else if strokeOpen && strokeIsTablet {
                end(at: lastPoint, pressure: lastContactPressure, isTablet: true)
            }
        case PALIMPSEST_EVENT_TABLET_BUTTON:
            guard event.pressed == 1 else { return }
            // BTN_STYLUS / BTN_STYLUS2, or whatever eraser_button_override emits.
            LinuxLog.log(String(format: "tablet button code=0x%X pressed=%d", event.code, event.pressed))
            if event.code == 0x14C {
                pending.append(.clear)
            } else if event.code == 0x14B || event.code == 0x110 || event.code == 0x111 {
                pending.append(.toggle)
            }
        case PALIMPSEST_EVENT_KEY:
            handleKey(event)
        case PALIMPSEST_EVENT_KEYBOARD_FOCUS_RESET:
            ctrlKeys.removeAll()
        case PALIMPSEST_EVENT_CLOSED:
            LinuxLog.log("Compositor closed the overlay")
            finishInputSession()
        default:
            break
        }
    }

    private func handleKey(_ event: palimpsest_event) {
        let key = event.code
        if key == 29 || key == 97 {
            if event.pressed == 1 { ctrlKeys.insert(key) }
            if event.pressed == 0 { ctrlKeys.remove(key) }
            return
        }
        guard annotating, event.pressed != 0 else { return }
        let edge = event.pressed == 1
        let ctrl = !ctrlKeys.isEmpty
        if key == 1 && edge {
            pending.append(.cancel)
        } else if ctrl && key == 44 {
            pending.append(.undo)
        } else if ctrl && key == 14 && edge {
            pending.append(.clear)
        } else if ctrl && key == 46 && edge {
            pending.append(.copy)
        } else if ctrl && (key == 28 || key == 47) && edge {
            pending.append(.paste)
        }
    }

    private func globalPoint(outputID: Int32, x: Double, y: Double) -> Point {
        let info = outputInfos().first { $0.id == outputID }
        let originX = Double((info?.x ?? 0) + (info?.margin_left ?? 0))
        let originY = Double((info?.y ?? 0) + (info?.margin_top ?? 0))
        return Point(x: originX + x, y: originY + y)
    }

    private func begin(at point: Point, pressure: Double, isTablet: Bool) {
        guard annotating else { return }
        canvas.begin(at: StrokePoint(location: point, pressure: pressure, isTablet: isTablet))
        strokeOpen = true
        strokeIsTablet = isTablet
        dirty = true
    }

    private func extend(at point: Point, pressure: Double, isTablet: Bool) {
        guard annotating, strokeOpen else { return }
        canvas.extend(to: StrokePoint(location: point, pressure: pressure, isTablet: isTablet))
        dirty = true
    }

    private func end(at point: Point, pressure: Double, isTablet: Bool) {
        guard strokeOpen else { return }
        canvas.end(at: StrokePoint(location: point, pressure: pressure, isTablet: isTablet))
        strokeOpen = false
        dirty = true
    }

    // MARK: Commands

    func drainActions() {
        while !pending.isEmpty {
            let action = pending.removeFirst()
            perform(action)
        }
    }

    private func perform(_ action: Action) {
        switch action {
        case .toggle: toggleCaptureMode()
        case .copy: copy(paste: false)
        case .paste: copy(paste: true)
        case .undo: undo()
        case .clear: clear()
        case .cycle: cycleInkColour()
        case .cancel: cancelCapture()
        }
    }

    /// Barrel + tablet-v2 can fire the same press twice. Socket commands
    /// from the applet skip that window so a second click always stops.
    func toggleCaptureMode(ignoreDebounce: Bool = false) {
        let now = Date()
        if !ignoreDebounce, now.timeIntervalSince(lastToggleAt) < 0.35 {
            return
        }
        lastToggleAt = now
        LinuxLog.log(annotating ? "toggle off" : "toggle on")
        if annotating {
            if canvas.hasContent {
                copy(paste: config.deliveryAction == .copyAndPaste)
            } else {
                stopAnnotating()
            }
        } else {
            startAnnotating()
        }
    }

    func startAnnotating() {
        previousAddress = HyprlandWindow.active()?.address
        let insets = BarInsets.current()
        palimpsest_wl_set_margins(session, insets.top, insets.right, insets.bottom, insets.left)
        // Mapping can synchronously deliver keyboard-enter with held keys.
        // Reset the old input session before those events, not after them.
        beginInputSession()
        guard palimpsest_wl_show(session) == 0 else {
            finishInputSession()
            palimpsest_wl_hide(session)
            LinuxLog.log("Could not map the overlay")
            HUD.show("Could not show the overlay")
            return
        }
        for info in outputInfos() where info.buffer_width > 0 {
            LinuxLog.log(
                "overlay \(info.id) logical \(info.logical_width)x\(info.logical_height) "
                    + "buffer \(info.buffer_width)x\(info.buffer_height) scale \(info.scale) "
                    + "margin \(info.margin_top),\(info.margin_right),\(info.margin_bottom),\(info.margin_left)"
            )
        }
    }

    func stopAnnotating() {
        finishInputSession()
        palimpsest_wl_hide(session)
        _ = palimpsest_wl_roundtrip(session)
    }

    /// Input state boundaries are independent of mapping a compositor surface.
    /// Retain completed ink while ensuring an interrupted contact cannot resume.
    func beginInputSession() {
        finishInputSession()
        canvas.ink = config.palette.current
        annotating = true
        dirty = true
    }

    func finishInputSession() {
        if let last = canvas.current?.points.last { canvas.end(at: last) }
        annotating = false
        pointerDown = false
        penProximity = false
        tipDown = false
        strokeOpen = false
        paletteHold = false
        activeTouch = nil
        activeTouchOutput = -1
        ctrlKeys.removeAll()
    }

    func cancelCapture() {
        // Escape stops without copying or discarding the annotation.
        stopAnnotating()
    }

    func undo() {
        guard annotating else { return }
        if strokeOpen {
            strokeOpen = false
            pointerDown = false
            tipDown = false
        }
        canvas.undo()
        dirty = true
    }

    func clear() {
        canvas.clear()
        strokeOpen = false
        pointerDown = false
        tipDown = false
        dirty = true
    }

    func cycleInkColour() {
        var palette = config.palette
        palette.cycle()
        applyPalette(palette)
    }

    func selectInkColour(at index: Int) {
        var palette = config.palette
        palette.select(index)
        applyPalette(palette)
    }

    private func applyPalette(_ palette: Palette) {
        config.palette = palette
        guard persistConfig() else { return }
        canvas.ink = palette.current
        dirty = true
        LinuxLog.log("Ink \(palette.current.hex)")
    }

    @discardableResult
    func saveToFolder() -> Bool {
        guard annotating else { return false }
        return copy(paste: false, save: true, clipboard: false)
    }

    @discardableResult
    func copy(paste: Bool, save: Bool? = nil, clipboard: Bool = true) -> Bool {
        guard !rendering else { return false }
        rendering = true
        defer { rendering = false }

        let doSave = save ?? config.saveToDisk
        let address = previousAddress ?? HyprlandWindow.active()?.address
        let window = Self.captureWindow(address: address, client: HyprlandWindow.client, active: HyprlandWindow.active)
        guard let window, !window.frame.isEmpty else {
            LinuxLog.log("No window to capture")
            HUD.show("Nothing to copy")
            stopAnnotating()
            return false
        }

        let restore = annotating
        palimpsest_wl_hide(session)
        _ = palimpsest_wl_roundtrip(session)
        usleep(40_000)
        annotating = false

        let geometry = geometryString(window.frame)
        guard let grim = Tools.path("grim") else {
            LinuxLog.log("grim is not installed")
            HUD.show("Capture failed (grim missing)")
            restoreOverlay(restore)
            return false
        }
        let result = Shell.run(grim, arguments: ["-t", "ppm", "-g", geometry, "-"], timeout: 20)
        guard result.status == 0, let captured = PPMDecoder.decode(result.stdout) else {
            let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
            LinuxLog.log("grim failed status=\(result.status) \(stderr)")
            HUD.show("Capture failed")
            restoreOverlay(restore)
            return false
        }

        let prepared = config.softenPaper ? PaperTone.apply(to: captured) : captured
        let scaleX = Double(prepared.width) / window.frame.width
        let scaleY = Double(prepared.height) / window.frame.height
        let origin = Point(x: window.frame.minX, y: window.frame.minY)
        let flattened = Self.compositeInk(
            strokes: canvas.allStrokes(),
            style: canvas.style,
            onto: prepared,
            origin: origin,
            scaleX: scaleX,
            scaleY: scaleY
        ).flattened()

        if clipboard, !self.clipboard.writeNow(image: flattened, png: nil) {
            HUD.show("Clipboard write failed — ink kept")
            restoreOverlay(restore)
            return false
        }

        var saved = false
        if doSave {
            saved = LinuxHistory(folder: config.historyFolder).save(flattened) != nil
        }

        var pasted = false
        if paste && clipboard {
            let target = PasteTarget.choose(
                preference: config.pastePreference,
                previousApp: address,
                frontmostApp: HyprlandWindow.active()?.address,
                overrideApp: config.pasteOverride
            )
            pasted = paster.pasteSync(into: target)
        }

        HUD.show(Self.deliveryMessage(
            clipboard: clipboard, paste: paste, pasted: pasted, saved: saved, doSave: doSave
        ))

        previousAddress = nil
        stopAnnotating()
        return (!paste || pasted) && (!doSave || saved)
    }

    private static func deliveryMessage(
        clipboard: Bool, paste: Bool, pasted: Bool, saved: Bool, doSave: Bool
    ) -> String {
        var parts: [String] = []
        if clipboard {
            if paste {
                parts.append(pasted ? "Copied to clipboard — paste sent" : "Copied to clipboard (paste failed)")
            } else {
                parts.append("Copied to clipboard")
            }
        }
        if saved {
            parts.append(parts.isEmpty ? "Saved" : "saved")
        } else if doSave {
            parts.append("Save failed")
        }
        return parts.isEmpty ? "Copied to clipboard" : parts.joined(separator: " — ")
    }

    /// A remembered window may have closed while the overlay was visible.
    /// Never silently capture whichever unrelated window happens to be active.
    static func captureWindow(
        address: String?, client: (String) -> HyprlandWindow?, active: () -> HyprlandWindow?
    ) -> HyprlandWindow? {
        if let address, !address.isEmpty { return client(address) }
        return active()
    }

    private func restoreOverlay(_ restore: Bool) {
        guard restore else { return }
        if palimpsest_wl_show(session) == 0 {
            annotating = true
            dirty = true
        }
    }

    private func geometryString(_ frame: Rect) -> String {
        let x = Int(frame.minX.rounded())
        let y = Int(frame.minY.rounded())
        let width = max(Int(frame.width.rounded()), 1)
        let height = max(Int(frame.height.rounded()), 1)
        return "\(x),\(y) \(width)x\(height)"
    }

    static func compositeInk(
        strokes: [Stroke],
        style: StrokeStyle,
        onto image: ImageBuffer,
        origin: Point,
        scaleX: Double,
        scaleY: Double
    ) -> ImageBuffer {
        let widthScale = (scaleX + scaleY) / 2
        var style = style
        style.fixedWidth *= widthScale
        style.minWidth *= widthScale
        style.maxWidth *= widthScale
        let translated = strokes.map { stroke in
            Stroke(
                ink: stroke.ink,
                points: stroke.points.map { point in
                    StrokePoint(
                        location: Point(
                            x: (point.location.x - origin.x) * scaleX,
                            y: (point.location.y - origin.y) * scaleY
                        ),
                        pressure: point.pressure,
                        isTablet: point.isTablet
                    )
                }
            )
        }
        return BufferInkCompositor().composite(strokes: translated, style: style, onto: image)
    }

    // MARK: Drawing

    private func outputInfos() -> [palimpsest_output_info] {
        guard let session else { return [] }
        let count = palimpsest_wl_output_count(session)
        var infos: [palimpsest_output_info] = []
        for index in 0..<count {
            var info = palimpsest_output_info()
            if palimpsest_wl_output_info(session, index, &info) == 0 {
                infos.append(info)
            }
        }
        return infos
    }

    private func redrawAll() {
        guard annotating, let session else { return }
        for info in outputInfos() where info.buffer_width > 0 && info.buffer_height > 0 {
            let image = render(info)
            let status = image.withRawBytes { pointer -> Int32 in
                palimpsest_wl_present(
                    session, info.id,
                    pointer.assumingMemoryBound(to: UInt8.self),
                    Int32(image.width), Int32(image.height), Int32(image.width * 4)
                )
            }
            if status == -2 {
                dirty = true
            } else if status != 0 {
                LinuxLog.log("present failed for output \(info.id) (\(status))")
            }
        }
    }

    private func render(_ info: palimpsest_output_info) -> ImageBuffer {
        let width = Int(info.buffer_width)
        let height = Int(info.buffer_height)
        let background = ImageBuffer(
            width: width, height: height,
            pixels: [UInt8](repeating: 0, count: width * height * 4)
        )
        let scaleX = info.logical_width > 0 ? Double(info.buffer_width) / Double(info.logical_width) : Double(max(info.scale, 1))
        let scaleY = info.logical_height > 0 ? Double(info.buffer_height) / Double(info.logical_height) : scaleX
        let origin = Point(
            x: Double(info.x + info.margin_left),
            y: Double(info.y + info.margin_top)
        )
        var image = Self.compositeInk(
            strokes: canvas.allStrokes(),
            style: canvas.style,
            onto: background,
            origin: origin,
            scaleX: scaleX,
            scaleY: scaleY
        )
        if let hud = LinuxPaletteHUD.make(
            palette: config.palette,
            overlay: info,
            position: config.floatingPalettePosition
        ) {
            hud.paint(palette: config.palette, onto: &image, overlay: info)
        }
        return image
    }

    /// Overlay-local hit test for the floating swatch capsule. Clicks on the
    /// capsule never become ink, even if they miss a swatch.
    @discardableResult
    private func consumePaletteHit(outputID: Int32, x: Double, y: Double) -> Bool {
        guard annotating else { return false }
        guard let info = outputInfos().first(where: { $0.id == outputID }) else { return false }
        guard let hud = LinuxPaletteHUD.make(
            palette: config.palette,
            overlay: info,
            position: config.floatingPalettePosition
        ) else { return false }
        let local = Point(x: x, y: y)
        guard hud.frame.contains(local) else { return false }
        switch hud.hit(local) {
        case .select(let index):
            selectInkColour(at: index)
        case .clear:
            clear()
        case .save:
            saveToFolder()
        case nil:
            break
        }
        return true
    }

    // MARK: Control socket

    private func openControlSocket() {
        unlink(socketPath)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else {
            LinuxLog.log("socket() failed: \(String(cString: strerror(errno)))")
            return
        }
        var address = unixAddress(path: socketPath)
        let bound = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                bind(fd, sock, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            LinuxLog.log("bind(\(socketPath)) failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }
        _ = fchmod(fd, mode_t(0o600))
        guard listen(fd, 8) == 0 else {
            LinuxLog.log("listen failed")
            close(fd)
            return
        }
        controlFD = fd
    }

    private func acceptClient() {
        let fd = accept(controlFD, nil, nil)
        guard fd >= 0 else { return }
        // A client that stops reading must not freeze the overlay indefinitely.
        LinuxSocketIO.setTimeout(1000, option: SO_SNDTIMEO, fd: fd)
        clients.append(Client(fd: fd))
    }

    private func readClient(fd: Int32) {
        guard let client = clients.first(where: { $0.fd == fd }) else { return }
        var buffer = [UInt8](repeating: 0, count: 512)
        let count = recv(fd, &buffer, buffer.count, 0)
        guard count > 0 else {
            close(fd)
            clients.removeAll { $0.fd == fd }
            return
        }
        client.buffer.append(contentsOf: buffer.prefix(count))
        while let newline = client.buffer.firstIndex(of: 10) {
            guard client.buffer.distance(from: client.buffer.startIndex, to: newline) <= 4096,
                  let line = String(data: client.buffer.prefix(upTo: newline), encoding: .utf8) else {
                close(fd)
                clients.removeAll { $0.fd == fd }
                return
            }
            client.buffer.removeSubrange(...newline)
            let reply = handle(command: line.trimmingCharacters(in: .whitespacesAndNewlines))
            guard LinuxSocketIO.sendAll(Data((reply + "\n").utf8), to: fd) else {
                close(fd)
                clients.removeAll { $0.fd == fd }
                return
            }
        }
        if client.buffer.count > 4096 {
            close(fd)
            clients.removeAll { $0.fd == fd }
        }
    }

    func handle(command: String) -> String {
        configWriteFailed = false
        let reply = dispatch(command: command)
        return configWriteFailed ? "error: settings could not be saved; previous settings restored" : reply
    }

    @discardableResult
    private func persistConfig() -> Bool {
        guard config.store(at: configPath) else {
            configWriteFailed = true
            config = persistedConfig
            canvas.ink = config.palette.current
            dirty = true
            HUD.show("Settings could not be saved")
            return false
        }
        persistedConfig = config
        return true
    }

    private func dispatch(command: String) -> String {
        let parts = command.split(separator: " ").map(String.init)
        if parts.first != "status" && parts.first != "menu" {
            LinuxLog.log("command \(command)")
        }
        switch parts.first ?? "" {
        case "toggle":
            toggleCaptureMode(ignoreDebounce: true)
            return "ok annotating=\(annotating)"
        case "copy":
            guard copy(paste: false) else { return "error: copy failed; ink kept" }
            return "ok annotating=\(annotating)"
        case "paste":
            guard copy(paste: true) else { return "error: delivery failed; ink kept" }
            return "ok annotating=\(annotating)"
        case "save":
            guard annotating else { return "error: not annotating" }
            guard saveToFolder() else { return "error: save failed; ink kept" }
            return "ok annotating=\(annotating)"
        case "undo":
            undo()
            return "ok strokes=\(canvas.strokeCount)"
        case "clear":
            clear()
            return "ok strokes=0"
        case "colour", "color":
            if parts.count >= 2, let index = Int(parts[1]) {
                selectInkColour(at: index)
            } else {
                cycleInkColour()
            }
            return "ok ink=\(canvas.ink.hex) index=\(config.palette.index)"
        case "colour-add", "color-add":
            return handleColourAdd(parts)
        case "colour-remove", "color-remove":
            return handleColourRemove(parts)
        case "colour-name", "color-name":
            return handleColourName(parts)
        case "colour-replace", "color-replace":
            return handleColourReplace(parts)
        case "action":
            return handleAction(parts)
        case "paper-tone":
            return handlePaperTone(parts)
        case "save-annotations":
            return handleSaveAnnotations(parts)
        case "history":
            let history = LinuxHistory(folder: config.historyFolder)
            return "ok count=\(history.files().count) folder=\(history.folder)"
        case "history-open":
            return handleHistoryOpen(parts)
        case "folder":
            return handleFolder(parts)
        case "autostart":
            return handleAutostart(parts)
        case "pen-mouse":
            return handlePenMouse(parts)
        case "permissions":
            let line = permissionsLine()
            HUD.show(line.hasPrefix("ok ") ? String(line.dropFirst(3)).replacingOccurrences(of: "=", with: ": ") : line)
            return line
        case "paste-target":
            return handlePasteTarget(parts)
        case "palette-position":
            return handlePalettePosition(parts)
        case "menu":
            return menuJSON()
        case "hotkey":
            return "ok hotkey=\(Self.documentedHotkey)"
        case "cancel":
            cancelCapture()
            return "ok annotating=\(annotating)"
        case "status":
            return "annotating=\(annotating) strokes=\(canvas.strokeCount) ink=\(canvas.ink.hex) paste=\(config.pasteMenuTitle)"
        case "quit":
            linuxShouldQuit = 1
            return "ok"
        case "draw":
            return draw(parts: parts)
        default:
            return "unknown command: \(command)"
        }
    }

    private func handlePasteTarget(_ parts: [String]) -> String {
        if parts.count >= 2 {
            switch parts[1] {
            case "previous":
                config.pasteOverride = nil
                config.pasteOverrideName = nil
                config.pasteTarget = PasteTargetPreference.previousApp.rawValue
                persistConfig()
            case "frontmost":
                config.pasteOverride = nil
                config.pasteOverrideName = nil
                config.pasteTarget = PasteTargetPreference.frontmostApp.rawValue
                persistConfig()
            case "pin":
                guard parts.count >= 3 else {
                    return "error: paste-target pin ADDRESS [name]"
                }
                let address = parts[2]
                let name: String
                if parts.count > 3 {
                    name = parts[3...].joined(separator: " ")
                } else {
                    name = HyprlandWindow.client(address: address)?.displayName ?? address
                }
                config.pasteOverride = address
                config.pasteOverrideName = name
                persistConfig()
            default:
                return "error: paste-target previous|frontmost|pin ADDRESS"
            }
        }
        let override = config.pasteOverride ?? ""
        let name = config.pasteOverrideName ?? ""
        return "ok paste=\(config.pasteTarget) override=\(override) name=\(name)"
    }

    private func handlePalettePosition(_ parts: [String]) -> String {
        if parts.count >= 2 {
            guard let position = LinuxFloatingPalette(command: parts[1]) else {
                return "error: palette-position none|top-left|top-right"
            }
            config.floatingPalettePosition = position
            persistConfig()
            dirty = true
        }
        return "ok palette-position=\(config.floatingPalettePosition.rawValue)"
    }

    private func handleColourAdd(_ parts: [String]) -> String {
        let color: RGBA
        if parts.count >= 2 {
            let hex = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = RGBA(hex: hex) else {
                return "error: colour-add [hex]"
            }
            color = parsed
        } else if let next = LinuxColourNames.nextUnusedExtra(in: config.palette) {
            color = next
        } else {
            return "error: no unused colours"
        }
        var palette = config.palette
        palette.add(color)
        applyPalette(palette)
        return "ok ink=\(canvas.ink.hex) index=\(config.palette.index)"
    }

    private func handleColourRemove(_ parts: [String]) -> String {
        guard parts.count >= 2, let index = Int(parts[1]) else {
            return "error: colour-remove N"
        }
        var palette = config.palette
        guard palette.colors.indices.contains(index) else {
            return "error: colour-remove N"
        }
        guard palette.colors.count > 1 else {
            return "error: last colour cannot be removed"
        }
        let removed = palette.colors[index]
        palette.remove(at: index)
        if !palette.colors.contains(removed) {
            var names = config.names
            names.removeValue(forKey: removed.hex)
            config.names = names
        }
        applyPalette(palette)
        return "ok ink=\(canvas.ink.hex) index=\(config.palette.index)"
    }

    private func handleColourName(_ parts: [String]) -> String {
        guard parts.count >= 2, let index = Int(parts[1]) else {
            return "error: colour-name N NAME..."
        }
        let palette = config.palette
        guard palette.colors.indices.contains(index) else {
            return "error: colour-name N NAME..."
        }
        let color = palette.colors[index]
        let name = parts.count > 2
            ? parts[2...].joined(separator: " ").trimmingCharacters(in: .whitespaces)
            : ""
        var names = config.names
        if name.isEmpty {
            names.removeValue(forKey: color.hex)
        } else {
            names[color.hex] = name
        }
        config.names = names
        persistConfig()
        return "ok index=\(index) name=\(config.displayName(for: color))"
    }

    private func handleColourReplace(_ parts: [String]) -> String {
        guard parts.count >= 3, let index = Int(parts[1]), let color = RGBA(hex: parts[2]) else {
            return "error: colour-replace N HEX"
        }
        var palette = config.palette
        guard palette.colors.indices.contains(index) else {
            return "error: colour-replace N HEX"
        }
        let old = palette.colors[index]
        // Palette.replace selects an existing colour without replacing the old
        // swatch, so in that case both existing colour names must remain intact.
        if old != color, !palette.colors.contains(color), let name = config.names[old.hex] {
            var names = config.names
            names.removeValue(forKey: old.hex)
            names[color.hex] = name
            config.names = names
        }
        palette.replace(at: index, with: color)
        applyPalette(palette)
        return "ok ink=\(canvas.ink.hex) index=\(config.palette.index)"
    }

    private func handleAction(_ parts: [String]) -> String {
        if parts.count >= 2 {
            guard let value = LinuxDeliveryAction(command: parts[1]) else {
                return "error: action clipboard|copy-and-paste"
            }
            config.deliveryAction = value
            persistConfig()
        }
        return "ok action=\(config.deliveryAction.rawValue)"
    }

    private func handlePaperTone(_ parts: [String]) -> String {
        if parts.count >= 2 {
            guard let value = parseOnOff(parts[1]) else {
                return "error: paper-tone on|off"
            }
            config.paperTone = value
            persistConfig()
        }
        return "ok paper-tone=\(config.softenPaper ? "on" : "off")"
    }

    private func handleSaveAnnotations(_ parts: [String]) -> String {
        if parts.count >= 2 {
            guard let value = parseOnOff(parts[1]) else {
                return "error: save-annotations on|off"
            }
            config.saveAnnotations = value
            persistConfig()
        }
        return "ok save-annotations=\(config.saveToDisk ? "on" : "off")"
    }

    private func handleHistoryOpen(_ parts: [String]) -> String {
        let history = LinuxHistory(folder: config.historyFolder)
        let path = parts.count >= 2 ? parts[1...].joined(separator: " ") : nil
        guard history.reveal(path) else {
            return "error: history-open"
        }
        return "ok"
    }

    private func handleFolder(_ parts: [String]) -> String {
        if parts.count >= 2 {
            let path = parts[1...].joined(separator: " ")
            guard !path.isEmpty else {
                return "error: folder PATH"
            }
            do { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
            catch { return "error: annotations folder is unavailable" }
            config.historyFolder = path
            persistConfig()
        }
        return "ok folder=\(config.historyFolder)"
    }

    private func handleAutostart(_ parts: [String]) -> String {
        if parts.count >= 2 {
            guard let value = parseOnOff(parts[1]) else {
                return "error: autostart on|off"
            }
            guard LinuxAutostart.setEnabled(value) else {
                return "error: autostart write failed"
            }
            config.launchOnStartup = value
            persistConfig()
        }
        return "ok autostart=\(LinuxAutostart.isEnabled() ? "on" : "off")"
    }

    private func handlePenMouse(_ parts: [String]) -> String {
        if parts.count >= 2 {
            return "error: idle pen pointer behaviour is controlled by Hyprland"
        }
        return "ok pen-mouse=system-controlled"
    }

    private func permissionsLine() -> String {
        func present(_ name: String) -> String {
            Tools.path(name) != nil ? "yes" : "no"
        }
        stylusMonitor.openIfNeeded(force: true)
        let stylus = stylusMonitor.fd >= 0 ? "yes" : "no"
        return "ok grim=\(present("grim")) wl-copy=\(present("wl-copy")) wtype=\(present("wtype")) hyprctl=\(present("hyprctl")) stylus=\(stylus)"
    }

    private func parseOnOff(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "on", "true", "1", "yes": return true
        case "off", "false", "0", "no": return false
        default: return nil
        }
    }

    private func menuJSON() -> String {
        let palette = config.palette
        var paletteItems: [[String: Any]] = []
        for (index, color) in palette.colors.enumerated() {
            paletteItems.append([
                "index": index,
                "hex": color.hex,
                "name": config.displayName(for: color),
                "selected": index == palette.index
            ])
        }
        let active = HyprlandWindow.active()?.address
        var windows: [[String: Any]] = []
        for window in HyprlandWindow.all() {
            guard let address = window.address, !address.isEmpty else { continue }
            windows.append([
                "address": address,
                "title": window.displayName,
                "class": window.className ?? "",
                "active": address == active
            ])
        }
        windows.sort { left, right in
            let a = (left["title"] as? String ?? "").localizedCaseInsensitiveCompare(right["title"] as? String ?? "")
            return a == .orderedAscending
        }
        let pinAvailable = config.pasteOverride.map { pinned in
            windows.contains { $0["address"] as? String == pinned }
        } ?? true
        let historyItems: [[String: Any]] = LinuxHistory(folder: config.historyFolder).files().map { entry in
            ["path": entry.path, "name": entry.name]
        }
        let object: [String: Any] = [
            "annotating": annotating,
            "strokes": canvas.strokeCount,
            "ink": canvas.ink.hex,
            "paletteIndex": palette.index,
            "palette": paletteItems,
            "pasteTarget": config.pasteTarget,
            "pasteOverride": config.pasteOverride as Any? ?? NSNull(),
            "pasteOverrideName": config.pasteOverrideName as Any? ?? NSNull(),
            "pasteTitle": config.pasteMenuTitle(pinAvailable: pinAvailable),
            "pasteOverrideAvailable": pinAvailable,
            "palettePosition": config.floatingPalettePosition.rawValue,
            "action": config.deliveryAction.rawValue,
            "saveAnnotations": config.saveToDisk,
            "paperTone": config.softenPaper,
            "launchOnStartup": LinuxAutostart.isEnabled(),
            "penMouseManagedBySystem": true,
            "folder": config.historyFolder,
            "history": historyItems,
            "extras": LinuxColourNames.unusedExtras(in: palette),
            "pasteShown": config.deliveryAction == .copyAndPaste,
            "hotkey": Self.documentedHotkey,
            "picker": Tools.path("hyprpicker") != nil,
            "windows": windows
        ]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return "error: menu encode"
        }
        return text
    }

    /// Test hook: `draw x,y x,y` adds one straight stroke in global logical pixels.
    private func draw(parts: [String]) -> String {
        guard parts.count >= 3, let start = Point(csv: parts[1]), let endPoint = Point(csv: parts[2]) else {
            return "error: draw x,y x,y"
        }
        guard annotating else { return "error: not annotating" }
        canvas.begin(at: StrokePoint(location: start, pressure: 1, isTablet: false))
        canvas.extend(to: StrokePoint(location: endPoint, pressure: 1, isTablet: false))
        canvas.end(at: StrokePoint(location: endPoint, pressure: 1, isTablet: false))
        strokeOpen = false
        dirty = true
        return "ok strokes=\(canvas.strokeCount)"
    }
}

private extension Point {
    init?(csv: String) {
        let pieces = csv.split(separator: ",")
        guard pieces.count == 2, let x = Double(pieces[0]), let y = Double(pieces[1]) else { return nil }
        self.init(x: x, y: y)
    }
}

enum BarInsets {
    /// Logical pixels to keep clear so a layer-shell bar stays clickable.
    static func current() -> (top: Int32, right: Int32, bottom: Int32, left: Int32) {
        let data = Shell.hyprctl("-j", "layers")
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (0, 0, 0, 0)
        }
        var top = 0, right = 0, bottom = 0, left = 0
        for (_, monitorValue) in root {
            guard let monitor = monitorValue as? [String: Any],
                  let levels = monitor["levels"] as? [String: Any] else { continue }
            for (_, levelValue) in levels {
                guard let entries = levelValue as? [Any] else { continue }
                for entryValue in entries {
                    guard let entry = entryValue as? [String: Any] else { continue }
                    let namespace = (entry["namespace"] as? String ?? "").lowercased()
                    guard namespace.contains("bar") else { continue }
                    let x = JSONNumber.int(entry["x"])
                    let y = JSONNumber.int(entry["y"])
                    let width = JSONNumber.int(entry["w"])
                    let height = JSONNumber.int(entry["h"])
                    guard width > 0, height > 0 else { continue }
                    if height <= 96 && width > height {
                        if y <= 1 { top = max(top, height) }
                        else { bottom = max(bottom, height) }
                    } else if width <= 96 && height > width {
                        if x <= 1 { left = max(left, width) }
                        else { right = max(right, width) }
                    }
                }
            }
        }
        return (Int32(top), Int32(right), Int32(bottom), Int32(left))
    }
}

enum JSONNumber {
    static func int(_ value: Any?) -> Int {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number.rounded()) }
        if let number = value as? NSNumber { return number.intValue }
        return 0
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }
}

enum HUD {
    static func show(_ message: String) {
        LinuxLog.log(message)
        guard let tool = Tools.path("notify-send") else { return }
        _ = Shell.run(tool, arguments: ["-a", "ScribbleEverywhere", "-u", "low", "-t", "1600", "ScribbleEverywhere", message])
    }
}

enum Tools {
    static func path(_ name: String) -> String? {
        if name == "wtype" && FileManager.default.isExecutableFile(atPath: "/usr/bin/wtype") {
            return "/usr/bin/wtype"
        }
        let directories = (env("PATH") ?? "/usr/local/sbin:/usr/local/bin:/usr/bin:/bin").split(separator: ":")
        for directory in directories {
            let candidate = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

extension ImageBuffer {
    func withRawBytes<R>(_ body: (UnsafeRawPointer) -> R) -> R {
        pixels.withUnsafeBytes { raw in
            body(raw.baseAddress!)
        }
    }
}

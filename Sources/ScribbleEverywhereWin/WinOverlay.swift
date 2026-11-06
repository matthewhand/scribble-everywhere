import Foundation
import WinSDK
import PalimpsestCore

/// Transparent topmost overlay window covering one display, in the same spirit
/// as the macOS `OverlayWindow`/`OverlayManager`.
///
/// - `WS_EX_LAYERED | WS_EX_TRANSPARENT` while idle (click-through), which is
///   flipped off during annotation so the window receives pen/touch/mouse.
/// - Ink is drawn with GDI on the layered window during annotation; the final
///   image is composited from the stroke model (not the pixels) by
///   `BufferInkCompositor`, exactly like macOS.
@MainActor
final class WinOverlay: PalimpsestCore.OverlayHost {
    static let className = "PalimpsestInkOverlay"
    /// Opt-in runtime validation: expose the real overlay to window automation.
    /// Normal use retains the tool-window style and stays out of the taskbar.
    static var validationWindow = false

    private var hwnd: HWND?
    private var canvas: StrokeCanvas?
    private var display: WinDisplays.Info?
    private var penActive = false
    /// True while WM_POINTER is drawing this contact. Synthesized mouse for that
    /// contact is ignored. If pointer messages never arrive, the mouse messages
    /// still draw, which is how this Surface pen reports contact.
    private var acceptingPointerStroke = false
    private var activePointerId: UINT32?
    /// Barrel (tip) button held. A rising edge toggles annotation.
    private var barrelHeld = false
    private var lastPoint = Point(x: 0, y: 0)
    private var lastPressure = 0.0

    // MARK: Cached GDI resources
    //
    // Allocating a full-screen DIB section and pushing the whole buffer through
    // UpdateLayeredWindow on every pen sample is too slow: it re-stamps every
    // stroke and blits the entire display per point, which is why ink lags the
    // pen. Keep the DIB, the memory DC and the screen DC alive for the life of
    // the overlay and only blit the small rectangle that changed.
    private var pixels: [UInt32] = []
    private var dibSize = (width: 0, height: 0)
    private var dib: HBITMAP?
    private var dibBits: UnsafeMutableRawPointer?
    private var memDC: HDC?

    /// Index into `canvas.allStrokes()` of the next segment to stamp. Segments
    /// before this are already in `pixels`; only new ones are drawn per frame.
    private var stampedStrokeCount = 0
    private var stampedPointCounts: [Int] = []

    var isClickThrough: Bool = true {
        didSet { applyClickThrough() }
    }

    var onStrokeChanged: (() -> Void)?
    var onCancel: (() -> Void)?
    var onUndo: (() -> Void)?
    var onClear: (() -> Void)?
    var onCopy: (() -> Void)?
    var onCopyAndPaste: (() -> Void)?
    var onToggle: (() -> Void)?
    var matchesToggleHotkey: ((UInt32, UInt32) -> Bool)?

    static func registerClass() {
        var wc = WNDCLASSEXW()
        wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        wc.lpfnWndProc = wndProc
        wc.hInstance = GetModuleHandleW(nil)
        // Magenta is the layered color key, so unpainted pixels stay click-visible as transparent.
        wc.hbrBackground = CreateSolidBrush(makeColorref(RGBA(r: 255, g: 0, b: 255)))
        // IDC_CROSS is MAKEINTRESOURCE(32515) and is not imported.
        wc.hCursor = LoadCursorW(nil, UnsafePointer(bitPattern: 32515))
        let name = className.wide
        name.withUnsafeBufferPointer { buffer in
            wc.lpszClassName = buffer.baseAddress
            if RegisterClassExW(&wc) == 0 {
                WinLog.log("RegisterClassExW failed \(GetLastError())")
            }
        }
    }

    func attach(canvas: StrokeCanvas) {
        self.canvas = canvas
    }

    func show(onDisplay displayID: UInt32) {
        guard canvas != nil else { return }

        let displays = WinDisplays.all()
        let target = displays.first { $0.id == displayID } ?? displays.first
        guard let target else {
            WinLog.log("No display to place overlay on")
            return
        }
        display = target

        if hwnd == nil {
            hwnd = createWindow()
            if let hwnd {
                Self.registry[hwnd] = self
                // Pen and touch already use WM_POINTER. Enabling mouse-in-pointer
                // would also reroute physical mouse input to PT_MOUSE, which this
                // overlay handles through the ordinary WM_MOUSE messages instead.
            }
        }
        guard let hwnd else { return }

        // isClickThrough is set before the HWND exists on the first show, so
        // didSet does not run. Apply it now that the window is real.
        applyClickThrough()

        // HWND_TOPMOST is ((HWND)-1) and is not imported.
        SetWindowPos(
            hwnd,
            HWND(bitPattern: -1),
            Int32(target.frame.minX), Int32(target.frame.minY),
            Int32(target.frame.width), Int32(target.frame.height),
            UInt32(SWP_NOACTIVATE)
        )
        if isClickThrough {
            ShowWindow(hwnd, SW_SHOWNOACTIVATE)
        } else {
            ShowWindow(hwnd, SW_SHOW)
            let focused = SetForegroundWindow(hwnd)
            WinLog.log("overlay SetForegroundWindow=\(focused)")
            present(reset: true)
        }
    }

    func hide() {
        guard let hwnd else { return }
        finishContact()
        ShowWindow(hwnd, SW_HIDE)
    }

    func clear() {
        guard hwnd != nil else { return }
        invalidateWholeWindow()
    }

    private func invalidateWholeWindow() {
        present(reset: true)
    }

    private func applyClickThrough() {
        guard let hwnd else { return }
        if isClickThrough { finishContact() }
        let current = UInt32(bitPattern: GetWindowLongW(hwnd, GWL_EXSTYLE))
        let blocked = UInt32(WS_EX_TRANSPARENT | WS_EX_NOACTIVATE)
        let kinds = UInt32(WS_EX_TOOLWINDOW | WS_EX_APPWINDOW)
        let kind = UInt32(Self.validationWindow ? WS_EX_APPWINDOW : WS_EX_TOOLWINDOW)
        var style = (current & ~blocked & ~kinds) | UInt32(WS_EX_LAYERED | WS_EX_TOPMOST) | kind
        if isClickThrough {
            style |= blocked
        }
        _ = SetWindowLongW(hwnd, GWL_EXSTYLE, Int32(bitPattern: style))
    }

    private func createWindow() -> HWND? {
        guard let display else { return nil }
        let hwnd = CreateWindowExW(
            DWORD(WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_NOACTIVATE)
                | DWORD(Self.validationWindow ? WS_EX_APPWINDOW : WS_EX_TOOLWINDOW),
            Self.className.wide,
            (Self.validationWindow ? "ScribbleEverywhere — Input validation" : "ScribbleEverywhere").wide,
            DWORD(WS_POPUP),
            Int32(display.frame.minX), Int32(display.frame.minY),
            Int32(display.frame.width), Int32(display.frame.height),
            nil, nil, GetModuleHandleW(nil), nil
        )
        guard let hwnd else { return nil }
        return hwnd
    }

    /// Per-pixel alpha, not a color key. A color-keyed pixel is click-through, so
    /// the first pen or mouse sample would fall through the empty overlay.
    /// Alpha 1 is invisible enough to see the screen and solid enough to hit-test.
    ///
    /// The DIB section and memory DC are cached for the overlay's
    /// life; `reset` re-fills the veil and re-stamps every stroke (show, clear,
    /// undo, ink change). Otherwise only segments not yet in `pixels` are
    /// stamped and only their bounding rectangle is blitted, which keeps ink
    /// under a fast pen instead of a frame behind it.
    private func present(reset: Bool) {
        guard let hwnd, let display, let canvas, !isClickThrough else { return }
        let width = max(Int(display.frame.width.rounded()), 1)
        let height = max(Int(display.frame.height.rounded()), 1)
        let count = width * height
        // A resized DIB needs a complete copy even if its pixel count happens
        // to match the previous display (for example, after rotation).
        let fullRedraw = reset || dibSize.width != width || dibSize.height != height

        if pixels.count != count {
            fillVeil(count: count)
            stampedStrokeCount = 0
            stampedPointCounts = []
        } else if fullRedraw {
            fillVeil(count: count)
            stampedStrokeCount = 0
            stampedPointCounts = []
        }

        ensureDib(width: width, height: height)
        guard dibBits != nil, let memDC else { return }
        guard let screenDC = GetDC(nil) else { return }
        defer { ReleaseDC(nil, screenDC) }

        var dirty = fullRedraw ? RECT(left: 0, top: 0, right: Int32(width), bottom: Int32(height)) : RECT(left: 0, top: 0, right: 0, bottom: 0)
        var style = StrokeStyle.standard
        style.fixedWidth *= display.scale
        style.minWidth *= display.scale
        style.maxWidth *= display.scale

        let strokes = canvas.allStrokes()
        for (index, stroke) in strokes.enumerated() {
            if index < stampedPointCounts.count, stroke.points.count <= stampedPointCounts[index] {
                continue
            }
            let skip = index < stampedPointCounts.count ? stampedPointCounts[index] : 0
            stampSegments(
                stroke: stroke, from: skip, style: style, display: display,
                width: width, height: height, dirty: &dirty
            )
            if index < stampedPointCounts.count {
                stampedPointCounts[index] = stroke.points.count
            } else {
                stampedPointCounts.append(stroke.points.count)
            }
        }
        stampedStrokeCount = strokes.count
        // Strokes removed by undo/clear shift the array; a reset re-stamps all.
        if stampedPointCounts.count > strokes.count {
            stampedPointCounts.removeLast(stampedPointCounts.count - strokes.count)
        }

        // Copy changed pixels from Swift buffer to DIB bits.
        // On reset copy the whole buffer; on incremental copy only dirty rows.
        if let dibBits {
            let dst = dibBits.assumingMemoryBound(to: UInt32.self)
            pixels.withUnsafeBytes { srcBytes in
                guard let srcBase = srcBytes.baseAddress else { return }
                let src = srcBase.assumingMemoryBound(to: UInt32.self)
                if fullRedraw {
                    memcpy(dst, src, pixels.count * 4)
                } else if dirty.left < dirty.right && dirty.top < dirty.bottom {
                    let stride = width
                    for row in dirty.top..<dirty.bottom {
                        let rowOffset = Int(row) * stride
                        let rowCount = Int(dirty.right - dirty.left)
                        let srcOff = rowOffset + Int(dirty.left)
                        let dstOff = rowOffset + Int(dirty.left)
                        memcpy(dst.advanced(by: dstOff), src.advanced(by: srcOff), rowCount * 4)
                    }
                }
            }
        }

        var origin = POINT(x: Int32(display.frame.minX), y: Int32(display.frame.minY))
        var size = SIZE(cx: Int32(width), cy: Int32(height))
        var source = POINT(x: 0, y: 0)
        var blend = BLENDFUNCTION()
        blend.BlendOp = 0
        blend.BlendFlags = 0
        blend.SourceConstantAlpha = 255
        blend.AlphaFormat = 1
        // An empty dirty rect (right==left) means nothing changed; skip the blit.
        let hasDirty = dirty.left < dirty.right && dirty.top < dirty.bottom
        if fullRedraw || hasDirty {
            // Keep every pointee alive through the native call. Supplying a
            // dirty rect here avoids submitting the whole display per sample.
            let updated = withUnsafePointer(to: &origin) { destination in
                withUnsafePointer(to: &size) { dimensions in
                    withUnsafePointer(to: &source) { sourcePoint in
                        withUnsafePointer(to: &blend) { blendFunction in
                            withUnsafePointer(to: &dirty) { dirtyRect in
                                var update = UPDATELAYEREDWINDOWINFO()
                                update.cbSize = DWORD(MemoryLayout<UPDATELAYEREDWINDOWINFO>.size)
                                update.hdcDst = screenDC
                                update.pptDst = destination
                                update.psize = dimensions
                                update.hdcSrc = memDC
                                update.pptSrc = sourcePoint
                                update.pblend = blendFunction
                                update.dwFlags = DWORD(ULW_ALPHA)
                                update.prcDirty = fullRedraw ? nil : dirtyRect
                                return UpdateLayeredWindowIndirect(hwnd, &update)
                            }
                        }
                    }
                }
            }
            if !updated {
                WinLog.log("UpdateLayeredWindowIndirect failed \(GetLastError()); trying full update")
                if !UpdateLayeredWindow(hwnd, screenDC, &origin, &size, memDC, &source, 0, &blend, DWORD(ULW_ALPHA)) {
                    WinLog.log("UpdateLayeredWindow fallback failed \(GetLastError())")
                }
            }
        }
    }

    /// Allocate the DIB section and memory DC once per overlay size. Changed
    /// rows are copied from the Swift pixel buffer before the native update.
    private func ensureDib(width: Int, height: Int) {
        guard dib == nil || dibSize.width != width || dibSize.height != height else { return }
        // The bitmap must no longer be selected into a DC when it is deleted.
        if let memDC {
            _ = DeleteDC(memDC)
            self.memDC = nil
        }
        if let old = dib {
            _ = DeleteObject(old)
            dib = nil
            dibBits = nil
        }
        var info = BITMAPINFO()
        info.bmiHeader.biSize = UINT32(MemoryLayout<BITMAPINFOHEADER>.size)
        info.bmiHeader.biWidth = Int32(width)
        info.bmiHeader.biHeight = -Int32(height)
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        info.bmiHeader.biCompression = UInt32(BI_RGB)
        guard let screenDC = GetDC(nil) else { return }
        defer { ReleaseDC(nil, screenDC) }
        var bits: UnsafeMutableRawPointer?
        guard let dib = CreateDIBSection(screenDC, &info, UINT(DIB_RGB_COLORS), &bits, nil, 0), let bits else {
            WinLog.log("CreateDIBSection failed \(GetLastError())")
            return
        }
        guard let memDC = CreateCompatibleDC(screenDC) else {
            _ = DeleteObject(dib)
            return
        }
        _ = SelectObject(memDC, dib)
        self.dib = dib
        self.dibBits = bits
        self.memDC = memDC
        dibSize = (width, height)
    }

    private func fillVeil(count: Int) {
        if pixels.count != count {
            pixels = [UInt32](repeating: 0x28000000, count: count)
            return
        }
        pixels.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            let veil: UInt32 = 0x28000000
            var index = 0
            let limit = buffer.count
            while index + 8 <= limit {
                base[index] = veil
                base[index + 1] = veil
                base[index + 2] = veil
                base[index + 3] = veil
                base[index + 4] = veil
                base[index + 5] = veil
                base[index + 6] = veil
                base[index + 7] = veil
                index += 8
            }
            while index < limit {
                base[index] = veil
                index += 1
            }
        }
    }

    /// Stamp only the segments not yet drawn (`from` is the count of points
    /// already rendered for this stroke). Extends `dirty` to cover the pixels
    /// touched so the caller can blit just that rectangle.
    private func stampSegments(
        stroke: Stroke, from skip: Int, style: StrokeStyle,
        display: WinDisplays.Info, width: Int, height: Int, dirty: inout RECT
    ) {
        let samples = stroke.points
        guard !samples.isEmpty else { return }
        let color = premultiplied(stroke.ink)

        if samples.count == 1 {
            if skip == 0 {
                stampDisk(
                    at: samples[0].location,
                    radius: style.width(pressure: samples[0].pressure, isTablet: samples[0].isTablet) / 2,
                    color: color, display: display, width: width, height: height, dirty: &dirty
                )
            }
            return
        }

        // Start one point back so the joint between the last drawn sample and
        // the first new one is filled.
        let start = max(skip - 1, 0)
        guard start < samples.count - 1 else { return }
        for index in (start + 1)..<samples.count {
            let a = samples[index - 1]
            let b = samples[index]
            let radius = (style.width(pressure: a.pressure, isTablet: a.isTablet) + style.width(pressure: b.pressure, isTablet: b.isTablet)) / 4
            let dx = b.location.x - a.location.x
            let dy = b.location.y - a.location.y
            let distance = max(abs(dx), abs(dy))
            let steps = max(Int(distance / 2), 1)
            for step in 0...steps {
                let t = Double(step) / Double(steps)
                let point = Point(x: a.location.x + dx * t, y: a.location.y + dy * t)
                stampDisk(at: point, radius: radius, color: color, display: display, width: width, height: height, dirty: &dirty)
            }
        }
    }

    private func stampDisk(
        at point: Point, radius: Double, color: UInt32,
        display: WinDisplays.Info, width: Int, height: Int, dirty: inout RECT
    ) {
        let r = max(radius, 1)
        let cx = Int((point.x - display.frame.minX).rounded())
        let cy = Int((point.y - display.frame.minY).rounded())
        let ir = Int(r.rounded())
        let r2 = ir * ir
        var y = -ir
        while y <= ir {
            let py = cy + y
            var x = -ir
            while x <= ir {
                let px = cx + x
                if x * x + y * y <= r2, px >= 0, py >= 0, px < width, py < height {
                    pixels[py * width + px] = color
                }
                x += 1
            }
            y += 1
        }
        // Grow the dirty rectangle to include this disk.
        let minX = Int32(max(cx - ir, 0))
        let minY = Int32(max(cy - ir, 0))
        let maxX = Int32(min(cx + ir + 1, width))
        let maxY = Int32(min(cy + ir + 1, height))
        if dirty.right <= dirty.left && dirty.bottom <= dirty.top {
            dirty = RECT(left: minX, top: minY, right: maxX, bottom: maxY)
        } else {
            dirty.left = min(dirty.left, minX)
            dirty.top = min(dirty.top, minY)
            dirty.right = max(dirty.right, maxX)
            dirty.bottom = max(dirty.bottom, maxY)
        }
    }

    private func premultiplied(_ ink: RGBA) -> UInt32 {
        // BGRA, already premultiplied because source alpha is opaque.
        UInt32(ink.b) | (UInt32(ink.g) << 8) | (UInt32(ink.r) << 16) | 0xFF000000
    }

    // MARK: Drawing

    /// Paints all strokes into the layered window. Uses GDI ellipses, mirroring
    /// the compositor's segment-stamping (visual approximation only; the
    /// authoritative rendering for the clipboard is `BufferInkCompositor`).
    private func paint(hdc: HDC) {
        guard let canvas, let display else { return }
        // Scale the style by the display's DPI factor like macOS does.
        var style = StrokeStyle.standard
        style.fixedWidth *= display.scale
        style.minWidth *= display.scale
        style.maxWidth *= display.scale

        let compositor = GdiPreviewCompositor(scale: display.scale)
        _ = compositor.drawPreview(strokes: canvas.allStrokes(), style: style, hdc: hdc, origin: display.frame)
    }

    // MARK: WndProc dispatch

    nonisolated static let wndProc: WNDPROC = { hwnd, message, wParam, lParam in
        guard let hwnd else {
            return DefWindowProcW(nil, message, wParam, lParam)
        }
        switch UINT(message) {
        case UINT(WM_PAINT):
            var ps = PAINTSTRUCT()
            guard let hdc = BeginPaint(hwnd, &ps) else { return 0 }
            paintFor(hwnd: hwnd, hdc: hdc)
            EndPaint(hwnd, &ps)
            return 0
        case UINT(WM_POINTERDOWN):
            pointerEvent(hwnd: hwnd, message: message, wParam: wParam, lParam: lParam)
            return 0
        case UINT(WM_POINTERUPDATE):
            pointerEvent(hwnd: hwnd, message: message, wParam: wParam, lParam: lParam)
            return 0
        case UINT(WM_POINTERUP):
            pointerEvent(hwnd: hwnd, message: message, wParam: wParam, lParam: lParam)
            return 0
        case UINT(WM_POINTERCAPTURECHANGED):
            MainActor.assumeIsolated {
                guard let overlay = instanceFor(hwnd),
                      overlay.activePointerId == UINT32(UInt(wParam) & 0xFFFF) else { return }
                overlay.finishContact()
            }
            return 0
        case UINT(WM_CANCELMODE):
            MainActor.assumeIsolated { instanceFor(hwnd)?.finishContact() }
            return 0
        case UINT(WM_CAPTURECHANGED):
            MainActor.assumeIsolated {
                guard let overlay = instanceFor(hwnd), overlay.activePointerId == nil else { return }
                overlay.finishContact()
            }
            return 0
        case UINT(WM_LBUTTONDOWN):
            simplePoint(hwnd: hwnd, lParam: lParam, down: true)
            return 0
        case UINT(WM_MOUSEMOVE):
            if penActive(hwnd: hwnd) { simplePoint(hwnd: hwnd, lParam: lParam, down: nil) }
            return 0
        case UINT(WM_LBUTTONUP):
            simplePoint(hwnd: hwnd, lParam: lParam, down: false)
            return 0
        case UINT(WM_KEYDOWN), UINT(WM_SYSKEYDOWN):
            if keyDown(hwnd: hwnd, wParam: wParam) { return 0 }
            return DefWindowProcW(hwnd, message, wParam, lParam)
        case UINT(WM_DESTROY):
            return 0
        default:
            return DefWindowProcW(hwnd, message, wParam, lParam)
        }
    }

    nonisolated private static func paintFor(hwnd: HWND, hdc: HDC) {
        MainActor.assumeIsolated {
            guard let overlay = instanceFor(hwnd) else { return }
            overlay.paint(hdc: hdc)
        }
    }

    nonisolated private static func pointerEvent(hwnd: HWND, message: UINT, wParam: WPARAM, lParam: LPARAM) {
        MainActor.assumeIsolated {
            guard let overlay = instanceFor(hwnd) else { return }
            overlay.handlePointer(message: message, wParam: wParam, lParam: lParam)
        }
    }

    nonisolated private static func simplePoint(hwnd: HWND, lParam: LPARAM, down: Bool?) {
        MainActor.assumeIsolated {
            guard let overlay = instanceFor(hwnd) else { return }
            overlay.handleSimplePoint(lParam: lParam, down: down)
        }
    }

    nonisolated private static func penActive(hwnd: HWND) -> Bool {
        MainActor.assumeIsolated {
            instanceFor(hwnd)?.penActive ?? false
        }
    }

    nonisolated private static func keyDown(hwnd: HWND, wParam: WPARAM) -> Bool {
        MainActor.assumeIsolated {
            guard let overlay = instanceFor(hwnd) else { return false }
            return overlay.handleKey(wParam: wParam)
        }
    }

    nonisolated private static func instanceFor(_ hwnd: HWND) -> WinOverlay? {
        registry[hwnd]
    }

    /// hwnd -> instance. Small app; the dictionary stays tiny.
    nonisolated(unsafe) private static var registry: [HWND: WinOverlay] = [:]

    // MARK: Input handling

    /// Capture can disappear without a matching up event. Keep completed ink,
    /// end at the last known sample, and reset ownership before releasing capture
    /// (which can synchronously dispatch WM_CAPTURECHANGED).
    private func finishContact(cancel: Bool = false) {
        let wasActive = penActive
        penActive = false
        acceptingPointerStroke = false
        activePointerId = nil
        barrelHeld = false
        if wasActive, let canvas {
            if cancel {
                // Windows may cancel a touch after recognizing a palm. Do not
                // commit that rejected contact as permanent ink.
                if canvas.current != nil { canvas.undo() }
            } else if let last = canvas.current?.points.last {
                canvas.end(at: last)
            }
            onStrokeChanged?()
        }
        if let hwnd, GetCapture() == hwnd { _ = ReleaseCapture() }
        if cancel { present(reset: true) }
    }

    private func handlePointer(message: UINT, wParam: WPARAM, lParam: LPARAM) {
        guard canvas != nil else { return }

        // POINTER_FLAG_DOWN/UPDATE/UP and pressure come from GET_POINTER_INFO;
        // the simplified path uses the pointer type + position + pressure.
        var info = POINTER_INFO()
        // The pointer id is the low word. The high word is not part of the id.
        let pointerId = UINT32(UInt(wParam) & 0xFFFF)
        guard GetPointerInfo(pointerId, &info) else {
            notePointerFailure(pointerId)
            if message == UINT(WM_POINTERUP), activePointerId == pointerId { finishContact() }
            return
        }

        // ptPixelLocation is in screen pixels, the same space as capture and compositeInk.
        let local = Point(x: Double(info.ptPixelLocation.x), y: Double(info.ptPixelLocation.y))
        let kind = info.pointerType
        let isPen = kind == UInt32(PT_PEN.rawValue)
        let isTouch = kind == UInt32(PT_TOUCH.rawValue)
        guard isPen || isTouch, !isClickThrough else { return }
        if let activePointerId, activePointerId != pointerId { return }
        if (UInt32(info.pointerFlags) & UInt32(POINTER_FLAG_CANCELED)) != 0 {
            handlePointerContact(message: message, pointerId: pointerId,
                sample: StrokePoint(location: local, pressure: 0.5, isTablet: isPen),
                flags: UInt32(info.pointerFlags))
            return
        }

        var pressure = 0.5
        if isPen {
            var penInfo = POINTER_PEN_INFO()
            if GetPointerPenInfo(pointerId, &penInfo) {
                if (UInt32(penInfo.penMask) & UInt32(PEN_MASK_PRESSURE)) != 0 {
                    pressure = normalisedPressure(penInfo.pressure)
                }
                // PEN_FLAG_BARREL is 0x1. POINTER_FLAG_SECONDBUTTON is 0x20.
                // POINTER_FLAG_INCONTACT is 0x4. Hovering barrel presses do not draw.
                let flags = UInt32(penInfo.penFlags)
                let pointerFlags = UInt32(info.pointerFlags)
                let barrel = (flags & 0x1) != 0 || (pointerFlags & 0x20) != 0
                let inContact = (pointerFlags & 0x4) != 0
                if barrel && !barrelHeld {
                    barrelHeld = true
                    SurfacePenButton.noteTipPress("pointer")
                } else if !barrel {
                    barrelHeld = false
                }
                if barrel && !inContact && message != UINT(WM_POINTERUP) {
                    return
                }
            }
        }

        let sample = StrokePoint(location: local, pressure: pressure, isTablet: isPen)
        handlePointerContact(message: message, pointerId: pointerId, sample: sample, flags: UInt32(info.pointerFlags))
    }

    /// Shared contact state transition after Win32 has supplied the sample.
    /// Kept independent of GetPointerInfo so cancellation and ownership can be
    /// exercised without injecting input into the user's desktop.
    func handlePointerContact(message: UINT, pointerId: UINT32, sample: StrokePoint, flags: UInt32) {
        guard let canvas, !isClickThrough else { return }
        if let activePointerId, activePointerId != pointerId { return }
        if (flags & UInt32(POINTER_FLAG_CANCELED)) != 0 {
            if activePointerId == pointerId { finishContact(cancel: true) }
            return
        }
        switch message {
        case UINT(WM_POINTERDOWN):
            guard !penActive else { return }
            activePointerId = pointerId
            penActive = true
            acceptingPointerStroke = true
            canvas.begin(at: sample)
            WinLog.log("\(sample.isTablet ? "pen" : "touch") pointer down \(Int(sample.location.x)),\(Int(sample.location.y))")
        case UINT(WM_POINTERUPDATE):
            if penActive && activePointerId == pointerId,
               (flags & UInt32(POINTER_FLAG_INCONTACT)) != 0 {
                canvas.extend(to: sample)
            } else {
                return
            }
        case UINT(WM_POINTERUP):
            if penActive && activePointerId == pointerId {
                // Lifting a pen often reports zero pressure. Retain the contact
                // pressure so the final segment does not suddenly change width.
                let end = StrokePoint(location: sample.location, pressure: lastPressure, isTablet: sample.isTablet)
                canvas.end(at: end)
                penActive = false
                acceptingPointerStroke = false
                activePointerId = nil
                onStrokeChanged?()
            } else {
                return
            }
        default:
            return
        }
        invalidateAround(sample.location)
        lastPoint = sample.location
        lastPressure = sample.pressure
    }

    private func handleSimplePoint(lParam: LPARAM, down: Bool?) {
        guard let canvas, let hwnd, !isClickThrough else { return }
        // Pen and touch also synthesize mouse messages (extra-info signature 0xFF515700).
        // While a pointer owns a stroke, ignore both promoted and physical mouse
        // input so another device cannot extend or finish it.
        let extra = GetMessageExtraInfo()
        let fromPenOrTouch = (Int(extra) & 0xFFFFFF00) == 0xFF515700
        if acceptingPointerStroke { return }

        // GET_X/Y_LPARAM are signed, unlike LOWORD/HIWORD.
        var point = POINT(
            x: Int32(Int16(truncatingIfNeeded: lParam)),
            y: Int32(Int16(truncatingIfNeeded: Int(lParam) >> 16))
        )
        _ = ClientToScreen(hwnd, &point)
        let local = Point(x: Double(point.x), y: Double(point.y))
        let sample = StrokePoint(location: local, pressure: 0.5, isTablet: false)

        if let down {
            if down {
                guard !penActive else { return }
                penActive = true
                _ = SetCapture(hwnd)
                canvas.begin(at: sample)
                WinLog.log("\(fromPenOrTouch ? "pen" : "mouse") down \(Int(local.x)),\(Int(local.y))")
            } else if penActive {
                canvas.end(at: sample)
                penActive = false
                if GetCapture() == hwnd { _ = ReleaseCapture() }
                onStrokeChanged?()
            }
        } else if penActive {
            canvas.extend(to: sample)
        }
        invalidateAround(local)
        lastPoint = local
    }

    private func handleKey(wParam: WPARAM) -> Bool {
        let key = UInt32(truncatingIfNeeded: wParam)
        if key == UInt32(VK_ESCAPE) {
            onCancel?()
            return true
        }
        let ctrl = (GetKeyState(Int32(VK_CONTROL)) & Int16(bitPattern: 0x8000)) != 0
        let alt = (GetKeyState(Int32(VK_MENU)) & Int16(bitPattern: 0x8000)) != 0
        let shift = (GetKeyState(Int32(VK_SHIFT)) & Int16(bitPattern: 0x8000)) != 0
        let win = (GetKeyState(Int32(VK_LWIN)) & Int16(bitPattern: 0x8000)) != 0
            || (GetKeyState(Int32(VK_RWIN)) & Int16(bitPattern: 0x8000)) != 0
        let modifiers = (ctrl ? UInt32(MOD_CONTROL) : 0) | (alt ? UInt32(MOD_ALT) : 0)
            | (shift ? UInt32(MOD_SHIFT) : 0) | (win ? UInt32(MOD_WIN) : 0)
        // Focused key messages must honor the same configured binding as the
        // global registration, including extra/missing modifiers.
        if matchesToggleHotkey?(key, modifiers) == true {
            onToggle?()
            return true
        }
        guard ctrl else { return false }
        switch key {
        case 0x5A: // Z
            onUndo?()
            invalidateWholeWindow()
        case 0x43: // C
            onCopy?()
        case UInt32(VK_RETURN):
            onCopyAndPaste?()
        case UInt32(VK_BACK):
            onClear?()
            invalidateWholeWindow()
        default:
            return false
        }
        return true
    }

    private func invalidateAround(_ point: Point) {
        _ = point
        present(reset: false)
    }

    private var pointerFailures = 0

    private func notePointerFailure(_ pointerId: UINT32) {
        guard pointerFailures < 4 else { return }
        pointerFailures += 1
        WinLog.log("GetPointerInfo failed id=\(pointerId) err=\(GetLastError())")
    }

    /// Windows normalizes the digitizer's raw hardware range to 0...1024.
    /// Do not change the scale mid-stroke based on an out-of-range sample.
    private var pressureSamplesLogged = 0

    static func normalizedPressure(_ raw: UINT32) -> Double {
        min(Double(raw) / 1024, 1)
    }

    private func normalisedPressure(_ raw: UINT32) -> Double {
        if pressureSamplesLogged < 8 {
            pressureSamplesLogged += 1
            WinLog.log("pen pressure raw=\(raw) ceiling=1024")
        }
        return Self.normalizedPressure(raw)
    }
}

/// Draws strokes as GDI ellipses for the live preview.
private struct GdiPreviewCompositor {
    let scale: Double

    func drawPreview(strokes: [Stroke], style: StrokeStyle, hdc: HDC, origin: Rect) -> Bool {
        for stroke in strokes {
            let points = stroke.points
            guard !points.isEmpty else { continue }

            let brush = CreateSolidBrush(makeColorref(stroke.ink))
            defer { DeleteObject(brush) }
            let oldBrush = SelectObject(hdc, brush)
            let oldPen = SelectObject(hdc, GetStockObject(NULL_PEN))
            defer {
                _ = SelectObject(hdc, oldBrush)
                _ = SelectObject(hdc, oldPen)
            }

            if points.count == 1 {
                stamp(hdc: hdc, at: points[0], style: style, ink: stroke.ink, origin: origin)
                continue
            }
            for index in 1..<points.count {
                let a = points[index - 1]
                let b = points[index]
                let width = (style.width(pressure: a.pressure, isTablet: a.isTablet)
                    + style.width(pressure: b.pressure, isTablet: b.isTablet)) / 2
                // Step along the segment like the core compositor does.
                let dx = b.location.x - a.location.x
                let dy = b.location.y - a.location.y
                let distance = max(abs(dx), abs(dy))
                let steps = max(Int(distance / 2), 1)
                for step in 0...steps {
                    let t = Double(step) / Double(steps)
                    let point = StrokePoint(
                        location: Point(x: a.location.x + dx * t, y: a.location.y + dy * t),
                        pressure: a.pressure,
                        isTablet: a.isTablet
                    )
                    stampPoint(hdc: hdc, point: point.location, radius: width / 2, ink: stroke.ink, origin: origin)
                }
            }
        }
        return true
    }

    private func stamp(hdc: HDC, at point: StrokePoint, style: StrokeStyle, ink: RGBA, origin: Rect) {
        let width = style.width(pressure: point.pressure, isTablet: point.isTablet)
        stampPoint(hdc: hdc, point: point.location, radius: width / 2, ink: ink, origin: origin)
    }

    private func stampPoint(hdc: HDC, point: Point, radius: Double, ink: RGBA, origin: Rect) {
        let r = max(radius, 1)
        // Client coordinates: subtract the display's origin.
        let cx = point.x - origin.minX
        let cy = point.y - origin.minY
        _ = Ellipse(
            hdc,
            Int32(cx - r), Int32(cy - r),
            Int32(cx + r), Int32(cy + r)
        )
    }
}


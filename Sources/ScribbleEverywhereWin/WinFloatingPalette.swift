import Foundation
import WinSDK
import PalimpsestCore

/// Swatch bar shown only while annotating. It sits above the full-screen
/// overlay (`HWND_TOPMOST`, shown after the overlay) and does not activate,
/// so the overlay keeps keyboard focus. Position is configurable
/// (none / topLeft / topRight).
@MainActor
final class WinFloatingPalette {
    static let className = "PalimpsestInkPalette"

    var onSelect: ((Int) -> Void)?
    var onClear: (() -> Void)?
    var onSave: (() -> Void)?
    var onStop: (() -> Void)?

    private var hwnd: HWND?
    private var layout = Layout()
    private var visible = false
    private var lastHit: DWORD = 0

    static func registerClass() {
        var wc = WNDCLASSEXW()
        wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        wc.lpfnWndProc = wndProc
        wc.hInstance = GetModuleHandleW(nil)
        wc.hCursor = LoadCursorW(nil, UnsafePointer(bitPattern: 32512))
        let name = className.wide
        name.withUnsafeBufferPointer { buffer in
            wc.lpszClassName = buffer.baseAddress
            if RegisterClassExW(&wc) == 0 {
                WinLog.log("palette RegisterClassExW failed \(GetLastError())")
            }
        }
    }

    func show(palette: Palette, display: WinDisplays.Info, position: WinFloatingPosition = .topRight) {
        let rendered = render(palette: palette, scale: display.scale)
        layout = rendered.layout
        if hwnd == nil {
            hwnd = CreateWindowExW(
                DWORD(WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE),
                Self.className.wide,
                "ScribbleEverywhere Palette".wide,
                DWORD(WS_POPUP),
                0, 0, Int32(layout.width), Int32(layout.height),
                nil, nil, GetModuleHandleW(nil), nil
            )
            if let hwnd {
                Self.registry[hwnd] = self
            }
        }
        guard let hwnd else {
            WinLog.log("palette window failed \(GetLastError())")
            return
        }
        present(hwnd: hwnd, pixels: rendered.pixels)
        let margin = Int32((16 * display.scale).rounded())
        let x: Int32
        switch position {
        case .topLeft:
            x = Int32(display.frame.minX) + margin
        case .topRight:
            x = Int32(display.frame.maxX) - Int32(layout.width) - margin
        case .none:
            visible = false
            ShowWindow(hwnd, SW_HIDE)
            return
        }
        let y = Int32(display.frame.minY) + margin
        SetWindowPos(
            hwnd,
            HWND(bitPattern: -1),
            x, y, Int32(layout.width), Int32(layout.height),
            UINT(SWP_NOACTIVATE | SWP_SHOWWINDOW)
        )
        visible = true
        WinLog.log("palette shown \(layout.width)x\(layout.height) at \(x),\(y) pos=\(position)")
    }

    func update(palette: Palette) {
        guard visible, let hwnd else { return }
        var rect = RECT()
        guard GetWindowRect(hwnd, &rect) else { return }
        let scale = max(Double(layout.scale), 1)
        let rendered = render(palette: palette, scale: scale)
        layout = rendered.layout
        present(hwnd: hwnd, pixels: rendered.pixels)
        SetWindowPos(
            hwnd,
            HWND(bitPattern: -1),
            rect.left, rect.top, Int32(layout.width), Int32(layout.height),
            UINT(SWP_NOACTIVATE | SWP_SHOWWINDOW)
        )
    }

    func hide() {
        visible = false
        guard let hwnd else { return }
        ShowWindow(hwnd, SW_HIDE)
    }

    private struct Layout {
        var width = 0
        var height = 0
        var swatch = 0
        var gap = 0
        var pad = 0
        var count = 0
        var scale = 1.0
        var clearCenter = 0
        var saveCenter = 0
        var stopCenter = 0
    }

    private func render(palette: Palette, scale: Double) -> (pixels: [UInt32], layout: Layout) {
        let resolved = max(scale, 1)
        let swatch = max(Int((26 * resolved).rounded()), 18)
        let gap = max(Int((8 * resolved).rounded()), 4)
        let pad = max(Int((10 * resolved).rounded()), 6)
        let count = palette.colors.count
        let height = swatch + pad * 2
        let width = pad + count * (swatch + gap) + gap + swatch + gap + swatch + gap + swatch + pad
        var pixels = [UInt32](repeating: 0, count: width * height)
        fillCapsule(&pixels, width: width, height: height)
        for index in 0..<count {
            let cx = pad + swatch / 2 + index * (swatch + gap)
            let ring = index == palette.index ? max(Int((3 * resolved).rounded()), 2) : max(Int(resolved.rounded()), 1)
            fillCircle(&pixels, width: width, height: height, cx: cx, cy: height / 2, radius: Double(swatch) / 2, color: premultiply(b: 255, g: 255, r: 255, a: 255))
            fillCircle(
                &pixels, width: width, height: height,
                cx: cx, cy: height / 2,
                radius: Double(swatch) / 2 - Double(ring),
                color: inkPixel(palette.colors[index])
            )
        }
        let clearCenter = pad + count * (swatch + gap) + gap + swatch / 2
        let saveCenter = clearCenter + gap + swatch
        let stopCenter = saveCenter + gap + swatch
        drawClear(&pixels, width: width, height: height, cx: clearCenter, cy: height / 2, radius: Double(swatch) / 2 - 1)
        drawSave(&pixels, width: width, height: height, cx: saveCenter, cy: height / 2, radius: Double(swatch) / 2 - 1)
        drawStop(&pixels, width: width, height: height, cx: stopCenter, cy: height / 2, radius: Double(swatch) / 2 - 1)
        let layout = Layout(
            width: width, height: height, swatch: swatch, gap: gap, pad: pad,
            count: count, scale: resolved, clearCenter: clearCenter, saveCenter: saveCenter, stopCenter: stopCenter
        )
        return (pixels, layout)
    }

    private func inkPixel(_ color: RGBA) -> UInt32 {
        premultiply(b: color.b, g: color.g, r: color.r, a: color.a)
    }

    private func fillCapsule(_ pixels: inout [UInt32], width: Int, height: Int) {
        let radius = Double(height) / 2
        for y in 0..<height {
            for x in 0..<width {
                let px = Double(x) + 0.5
                let py = Double(y) + 0.5
                let cx = min(max(px, radius), Double(width) - radius)
                let distance = hypot(px - cx, py - radius)
                let coverage = circle(distance: distance, radius: radius - 0.5)
                if coverage <= 0 { continue }
                pixels[y * width + x] = premultiply(b: 0x2A, g: 0x2A, r: 0x2C, a: UInt8(coverage * 232))
            }
        }
    }

    private func fillCircle(_ pixels: inout [UInt32], width: Int, height: Int, cx: Int, cy: Int, radius: Double, color: UInt32) {
        guard radius > 0 else { return }
        let minX = max(Int(Double(cx) - radius - 1), 0)
        let maxX = min(Int(Double(cx) + radius + 1), width - 1)
        let minY = max(Int(Double(cy) - radius - 1), 0)
        let maxY = min(Int(Double(cy) + radius + 1), height - 1)
        var y = minY
        while y <= maxY {
            var x = minX
            while x <= maxX {
                let distance = hypot(Double(x) + 0.5 - Double(cx), Double(y) + 0.5 - Double(cy))
                let coverage = circle(distance: distance, radius: radius)
                if coverage > 0 {
                    let index = y * width + x
                    pixels[index] = over(pixels[index], fade(color, coverage))
                }
                x += 1
            }
            y += 1
        }
    }

    private func drawClear(_ pixels: inout [UInt32], width: Int, height: Int, cx: Int, cy: Int, radius: Double) {
        let white = premultiply(b: 255, g: 255, r: 255, a: 255)
        let minX = max(Int(Double(cx) - radius - 1), 0)
        let maxX = min(Int(Double(cx) + radius + 1), width - 1)
        let minY = max(Int(Double(cy) - radius - 1), 0)
        let maxY = min(Int(Double(cy) + radius + 1), height - 1)
        let ring = max(radius * 0.16, 1.5)
        var y = minY
        while y <= maxY {
            var x = minX
            while x <= maxX {
                let dx = Double(x) + 0.5 - Double(cx)
                let dy = Double(y) + 0.5 - Double(cy)
                let distance = hypot(dx, dy)
                var coverage = 0.0
                let outer = circle(distance: distance, radius: radius)
                let inner = circle(distance: distance, radius: radius - ring)
                coverage = max(outer - inner, 0)
                let arm = max(ring * 0.85, 1.4)
                let onX = abs(abs(dx) - abs(dy)) <= arm && distance < radius - ring
                if onX { coverage = 1 }
                if coverage > 0 {
                    let index = y * width + x
                    pixels[index] = over(pixels[index], fade(white, coverage))
                }
                x += 1
            }
            y += 1
        }
    }

    /// Square inside a ring, beside the clear mark, so annotation can end
    /// without the pen.
    private func drawStop(_ pixels: inout [UInt32], width: Int, height: Int, cx: Int, cy: Int, radius: Double) {
        let white = premultiply(b: 255, g: 255, r: 255, a: 255)
        let ring = max(radius * 0.16, 1.5)
        let half = max(radius * 0.36, 3)
        let minX = max(Int(Double(cx) - radius - 1), 0)
        let maxX = min(Int(Double(cx) + radius + 1), width - 1)
        let minY = max(Int(Double(cy) - radius - 1), 0)
        let maxY = min(Int(Double(cy) + radius + 1), height - 1)
        var y = minY
        while y <= maxY {
            var x = minX
            while x <= maxX {
                let dx = Double(x) + 0.5 - Double(cx)
                let dy = Double(y) + 0.5 - Double(cy)
                let distance = hypot(dx, dy)
                let outer = circle(distance: distance, radius: radius)
                let inner = circle(distance: distance, radius: radius - ring)
                var coverage = max(outer - inner, 0)
                if abs(dx) <= half && abs(dy) <= half { coverage = 1 }
                if coverage > 0 {
                    let index = y * width + x
                    pixels[index] = over(pixels[index], fade(white, coverage))
                }
                x += 1
            }
            y += 1
        }
    }

    /// Camera icon: a rounded rect with a lens circle, for "save".
    private func drawSave(_ pixels: inout [UInt32], width: Int, height: Int, cx: Int, cy: Int, radius: Double) {
        let white = premultiply(b: 255, g: 255, r: 255, a: 255)
        let ring = max(radius * 0.16, 1.5)
        let bodyW = max(radius * 0.75, 4)
        let bodyH = max(radius * 0.55, 3)
        let lensR = max(radius * 0.22, 1.5)
        let minX = max(Int(Double(cx) - radius - 1), 0)
        let maxX = min(Int(Double(cx) + radius + 1), width - 1)
        let minY = max(Int(Double(cy) - radius - 1), 0)
        let maxY = min(Int(Double(cy) + radius + 1), height - 1)
        var y = minY
        while y <= maxY {
            var x = minX
            while x <= maxX {
                let dx = Double(x) + 0.5 - Double(cx)
                let dy = Double(y) + 0.5 - Double(cy)
                let distance = hypot(dx, dy)
                let outer = circle(distance: distance, radius: radius)
                let inner = circle(distance: distance, radius: radius - ring)
                var coverage = max(outer - inner, 0)
                // Camera body
                if abs(dx) <= bodyW && abs(dy) <= bodyH {
                    coverage = 1
                }
                // Lens
                if dx * dx + dy * dy <= lensR * lensR {
                    coverage = max(coverage, 1)
                }
                if coverage > 0 {
                    let index = y * width + x
                    pixels[index] = over(pixels[index], fade(white, coverage))
                }
                x += 1
            }
            y += 1
        }
    }

    private func present(hwnd: HWND, pixels: [UInt32]) {
        var info = BITMAPINFO()
        info.bmiHeader.biSize = UINT32(MemoryLayout<BITMAPINFOHEADER>.size)
        info.bmiHeader.biWidth = Int32(layout.width)
        info.bmiHeader.biHeight = -Int32(layout.height)
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        info.bmiHeader.biCompression = UInt32(BI_RGB)
        var bits: UnsafeMutableRawPointer?
        guard let screen = GetDC(nil) else { return }
        defer { _ = ReleaseDC(nil, screen) }
        guard let dib = CreateDIBSection(screen, &info, UINT(DIB_RGB_COLORS), &bits, nil, 0), let bits else {
            WinLog.log("palette CreateDIBSection failed \(GetLastError())")
            return
        }
        defer { _ = DeleteObject(dib) }
        _ = pixels.withUnsafeBytes { raw in
            memcpy(bits, raw.baseAddress, pixels.count * 4)
        }
        guard let mem = CreateCompatibleDC(screen) else { return }
        defer { _ = DeleteDC(mem) }
        let old = SelectObject(mem, dib)
        defer { _ = SelectObject(mem, old) }
        var origin = POINT(x: 0, y: 0)
        var size = SIZE(cx: Int32(layout.width), cy: Int32(layout.height))
        var source = POINT(x: 0, y: 0)
        var blend = BLENDFUNCTION()
        blend.BlendOp = 0
        blend.BlendFlags = 0
        blend.SourceConstantAlpha = 255
        blend.AlphaFormat = 1
        var windowRect = RECT()
        _ = GetWindowRect(hwnd, &windowRect)
        origin = POINT(x: windowRect.left, y: windowRect.top)
        let updated = UpdateLayeredWindow(hwnd, screen, &origin, &size, mem, &source, 0, &blend, DWORD(2))
        if !updated {
            WinLog.log("palette UpdateLayeredWindow failed \(GetLastError())")
        }
    }

    private func hit(x: Int, y: Int) {
        WinLog.log("palette click \(x),\(y)")
        let now = GetTickCount()
        if now &- lastHit < 180 { return }
        let dy = y - layout.height / 2
        let radius = layout.swatch / 2 + 4
        let stopDx = x - layout.stopCenter
        if stopDx * stopDx + dy * dy <= radius * radius {
            lastHit = now
            WinLog.log("palette stop")
            onStop?()
            return
        }
        let saveDx = x - layout.saveCenter
        if saveDx * saveDx + dy * dy <= radius * radius {
            lastHit = now
            WinLog.log("palette save")
            onSave?()
            return
        }
        let dx = x - layout.clearCenter
        if dx * dx + dy * dy <= radius * radius {
            lastHit = now
            WinLog.log("palette clear")
            onClear?()
            return
        }
        for index in 0..<layout.count {
            let cx = layout.pad + layout.swatch / 2 + index * (layout.swatch + layout.gap)
            let sx = x - cx
            let sy = y - layout.height / 2
            if sx * sx + sy * sy <= radius * radius {
                lastHit = now
                WinLog.log("palette select \(index)")
                onSelect?(index)
                return
            }
        }
    }

    nonisolated static let wndProc: WNDPROC = { hwnd, message, wParam, lParam in
        guard let hwnd else { return DefWindowProcW(nil, message, wParam, lParam) }
        switch UINT(message) {
        case UINT(WM_LBUTTONDOWN):
            let x = Int(LOWORD(lParam))
            let y = Int(HIWORD(lParam))
            MainActor.assumeIsolated { registry[hwnd]?.hit(x: x, y: y) }
            return 0
        case UINT(WM_POINTERDOWN):
            let pointerId = UINT32(UInt(wParam) & 0xFFFF)
            var info = POINTER_INFO()
            guard GetPointerInfo(pointerId, &info) else { return 0 }
            var rect = RECT()
            _ = GetWindowRect(hwnd, &rect)
            let x = Int(info.ptPixelLocation.x - rect.left)
            let y = Int(info.ptPixelLocation.y - rect.top)
            MainActor.assumeIsolated { registry[hwnd]?.hit(x: x, y: y) }
            return 0
        case UINT(WM_POINTERUPDATE), UINT(WM_POINTERUP):
            return 0
        default:
            return DefWindowProcW(hwnd, message, wParam, lParam)
        }
    }

    nonisolated(unsafe) private static var registry: [HWND: WinFloatingPalette] = [:]
}

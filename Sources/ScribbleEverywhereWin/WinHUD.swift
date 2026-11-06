import Foundation
import WinSDK
import PalimpsestCore

/// On-screen confirmation, matching the macOS HUD. A tray balloon
/// (`NIF_INFO`) only lands in the Windows 11 notification center, so a stop
/// looks silent. This window does not activate and does not take clicks.
enum WinHUD {
    static let className = "PalimpsestInkHUD"
    static let timerId: UINT_PTR = 42

    nonisolated(unsafe) private static var window: HWND?
    nonisolated(unsafe) static var tray: HWND?

    static func registerClass() {
        var wc = WNDCLASSEXW()
        wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        wc.lpfnWndProc = hudWndProc
        wc.hInstance = GetModuleHandleW(nil)
        let name = className.wide
        name.withUnsafeBufferPointer { buffer in
            wc.lpszClassName = buffer.baseAddress
            if RegisterClassExW(&wc) == 0, GetLastError() != 1410 {
                WinLog.log("hud RegisterClassExW failed \(GetLastError())")
            }
        }
    }

    /// `tray` receives `WM_TIMER` because this window is click-through and the
    /// Swift executor does not run timers on its own.
    static func show(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let shown = String(trimmed.prefix(90))

        var cursor = POINT()
        _ = GetCursorPos(&cursor)
        let point = Point(x: Double(cursor.x), y: Double(cursor.y))
        let display = WinDisplays.display(containing: point) ?? WinDisplays.all().first
        let scale = max(display?.scale ?? 1, 1)

        guard let screen = GetDC(nil) else { return }
        defer { _ = ReleaseDC(nil, screen) }
        guard let mem = CreateCompatibleDC(screen) else { return }
        defer { _ = DeleteDC(mem) }

        guard let font = CreateFontW(
            -Int32((15 * scale).rounded()),
            0, 0, 0, 500,
            0, 0, 0,
            1, 0, 0, 4, 0x20,
            "Segoe UI".wide
        ) else {
            WinLog.log("hud CreateFontW failed \(GetLastError())")
            return
        }
        let oldFont = SelectObject(mem, font)
        defer {
            if oldFont != nil { _ = SelectObject(mem, oldFont) }
            _ = DeleteObject(font)
        }

        var wide = shown.wide
        var extent = SIZE()
        wide.withUnsafeMutableBufferPointer { buffer in
            _ = GetTextExtentPoint32W(mem, buffer.baseAddress, Int32(shown.utf16.count), &extent)
        }
        let padX = Int((18 * scale).rounded())
        let padY = Int((10 * scale).rounded())
        let width = max(Int(extent.cx) + padX * 2, Int((120 * scale).rounded()))
        let height = max(Int(extent.cy) + padY * 2, Int((36 * scale).rounded()))
        let radius = min(Double(height) / 2, 12 * scale)
        let pixels = fillRoundRect(width: width, height: height, radius: radius)

        var info = BITMAPINFO()
        info.bmiHeader.biSize = UINT32(MemoryLayout<BITMAPINFOHEADER>.size)
        info.bmiHeader.biWidth = Int32(width)
        info.bmiHeader.biHeight = -Int32(height)
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        info.bmiHeader.biCompression = UInt32(BI_RGB)
        var bits: UnsafeMutableRawPointer?
        guard let dib = CreateDIBSection(screen, &info, UINT(DIB_RGB_COLORS), &bits, nil, 0), let bits else {
            WinLog.log("hud CreateDIBSection failed \(GetLastError())")
            return
        }
        defer { _ = DeleteObject(dib) }
        _ = pixels.withUnsafeBytes { raw in
            memcpy(bits, raw.baseAddress, pixels.count * 4)
        }
        let old = SelectObject(mem, dib)
        defer { _ = SelectObject(mem, old) }

        _ = SetBkMode(mem, 1) // TRANSPARENT
        _ = SetTextColor(mem, COLORREF(0x00FFFFFF))
        var textRect = RECT(left: Int32(padX), top: 0, right: Int32(width - padX), bottom: Int32(height))
        wide.withUnsafeMutableBufferPointer { buffer in
            // DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX
            _ = DrawTextW(mem, buffer.baseAddress, -1, &textRect, UINT(0x0825))
        }
        repairTextAlpha(bits: bits, count: pixels.count)

        let originX = display.map { $0.frame.midX } ?? 0
        let originY = display.map { $0.frame.minY } ?? 0
        var x = Int32(originX - Double(width) / 2)
        let y = Int32(originY + 28 * scale)
        if let frame = display?.frame {
            let maxX = Int32(frame.maxX) - Int32(width) - 8
            let minX = Int32(frame.minX) + 8
            if x < minX { x = minX }
            if x > maxX { x = maxX }
        }

        if window == nil {
            window = CreateWindowExW(
                DWORD(WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | 0x20),
                className.wide,
                "ScribbleEverywhere HUD".wide,
                DWORD(WS_POPUP),
                x, y, Int32(width), Int32(height),
                nil, nil, GetModuleHandleW(nil), nil
            )
        }
        guard let hwnd = window else {
            WinLog.log("hud window failed \(GetLastError())")
            return
        }

        var origin = POINT(x: x, y: y)
        var size = SIZE(cx: Int32(width), cy: Int32(height))
        var source = POINT(x: 0, y: 0)
        var blend = BLENDFUNCTION()
        blend.BlendOp = 0
        blend.BlendFlags = 0
        blend.SourceConstantAlpha = 255
        blend.AlphaFormat = 1
        let updated = UpdateLayeredWindow(hwnd, screen, &origin, &size, mem, &source, 0, &blend, DWORD(2))
        if !updated {
            WinLog.log("hud UpdateLayeredWindow failed \(GetLastError())")
        }
        SetWindowPos(
            hwnd,
            HWND(bitPattern: -1),
            x, y, Int32(width), Int32(height),
            UINT(SWP_NOACTIVATE | SWP_SHOWWINDOW)
        )
        if let tray {
            _ = SetTimer(tray, timerId, 1600, nil)
        }
        WinLog.log("toast \(shown)")
    }

    static func hide() {
        if let tray {
            _ = KillTimer(tray, timerId)
        }
        if let window {
            ShowWindow(window, SW_HIDE)
        }
    }

    private static func fillRoundRect(width: Int, height: Int, radius: Double) -> [UInt32] {
        var pixels = [UInt32](repeating: 0, count: width * height)
        let r = min(radius, Double(min(width, height)) / 2)
        for y in 0..<height {
            for x in 0..<width {
                let px = Double(x) + 0.5
                let py = Double(y) + 0.5
                let cx = min(max(px, r), Double(width) - r)
                let cy = min(max(py, r), Double(height) - r)
                let coverage = max(0, min(1, r - hypot(px - cx, py - cy) + 0.5))
                if coverage <= 0 { continue }
                let alpha = UInt8((coverage * 236).rounded())
                pixels[y * width + x] = premultiply(b: 0x22, g: 0x22, r: 0x24, a: alpha)
            }
        }
        return pixels
    }

    /// GDI writes glyph pixels with alpha 0. Layered windows then drop them.
    private static func repairTextAlpha(bits: UnsafeMutableRawPointer, count: Int) {
        let pixels = bits.assumingMemoryBound(to: UInt32.self)
        for index in 0..<count {
            let pixel = pixels[index]
            if pixel >> 24 != 0 { continue }
            let blue = pixel & 0xFF
            let green = (pixel >> 8) & 0xFF
            let red = (pixel >> 16) & 0xFF
            let coverage = max(red, green, blue)
            if coverage == 0 { continue }
            pixels[index] = premultiply(b: 255, g: 255, r: 255, a: UInt8(coverage))
        }
    }

    private static func premultiply(b: UInt8, g: UInt8, r: UInt8, a: UInt8) -> UInt32 {
        let alpha = UInt32(a)
        let blue = UInt32(b) * alpha / 255
        let green = UInt32(g) * alpha / 255
        let red = UInt32(r) * alpha / 255
        return (alpha << 24) | (red << 16) | (green << 8) | blue
    }
}

private func hudWndProc(hwnd: HWND?, message: UINT, wParam: WPARAM, lParam: LPARAM) -> LRESULT {
    DefWindowProcW(hwnd, message, wParam, lParam)
}

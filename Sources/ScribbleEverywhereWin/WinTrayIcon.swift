import Foundation
import WinSDK

/// Tray icon: a dark rounded square with the three default ink colours.
/// The shell used to load IDI_APPLICATION, which is a blank window glyph.
enum WinTrayIcon {
    static func make() -> HICON? {
        let size = 32
        var pixels = [UInt32](repeating: 0, count: size * size)
        let margin = 1.0
        for y in 0..<size {
            for x in 0..<size {
                let coverage = roundRect(
                    x: Double(x) + 0.5, y: Double(y) + 0.5,
                    width: Double(size), height: Double(size),
                    radius: 7, inset: margin
                )
                if coverage <= 0 { continue }
                pixels[y * size + x] = premultiply(b: 0x22, g: 0x1E, r: 0x1E, a: UInt8(coverage * 255))
            }
        }
        stamp(&pixels, size: size, cx: 11, cy: 17, radius: 6.2, b: 48, g: 59, r: 255)
        stamp(&pixels, size: size, cx: 20, cy: 12, radius: 6.2, b: 255, g: 122, r: 0)
        stamp(&pixels, size: size, cx: 21, cy: 21, radius: 5.4, b: 89, g: 199, r: 52)

        guard let color = dib(pixels, size: size), let mask = CreateBitmap(Int32(size), Int32(size), 1, 1, nil) else {
            WinLog.log("tray icon bitmap failed \(GetLastError())")
            return nil
        }
        var info = ICONINFO()
        info.fIcon = WindowsBool(true)
        info.xHotspot = 0
        info.yHotspot = 0
        info.hbmMask = mask
        info.hbmColor = color
        let icon = CreateIconIndirect(&info)
        _ = DeleteObject(color)
        _ = DeleteObject(mask)
        if icon == nil {
            WinLog.log("CreateIconIndirect failed \(GetLastError())")
        }
        return icon
    }

    private static func stamp(_ pixels: inout [UInt32], size: Int, cx: Double, cy: Double, radius: Double, b: UInt8, g: UInt8, r: UInt8) {
        let color = premultiply(b: b, g: g, r: r, a: 255)
        let minX = max(Int(cx - radius - 1), 0)
        let maxX = min(Int(cx + radius + 1), size - 1)
        let minY = max(Int(cy - radius - 1), 0)
        let maxY = min(Int(cy + radius + 1), size - 1)
        var y = minY
        while y <= maxY {
            var x = minX
            while x <= maxX {
                let distance = hypot(Double(x) + 0.5 - cx, Double(y) + 0.5 - cy)
                let coverage = circle(distance: distance, radius: radius)
                if coverage > 0 {
                    let src = fade(color, coverage)
                    pixels[y * size + x] = over(pixels[y * size + x], src)
                }
                x += 1
            }
            y += 1
        }
    }

    private static func dib(_ pixels: [UInt32], size: Int) -> HBITMAP? {
        var info = BITMAPINFO()
        info.bmiHeader.biSize = UINT32(MemoryLayout<BITMAPINFOHEADER>.size)
        info.bmiHeader.biWidth = Int32(size)
        info.bmiHeader.biHeight = -Int32(size)
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        info.bmiHeader.biCompression = UInt32(BI_RGB)
        var bits: UnsafeMutableRawPointer?
        guard let screen = GetDC(nil) else { return nil }
        defer { _ = ReleaseDC(nil, screen) }
        guard let bitmap = CreateDIBSection(screen, &info, UINT(DIB_RGB_COLORS), &bits, nil, 0), let bits else {
            return nil
        }
        _ = pixels.withUnsafeBytes { raw in
            memcpy(bits, raw.baseAddress, pixels.count * 4)
        }
        return bitmap
    }
}

func premultiply(b: UInt8, g: UInt8, r: UInt8, a: UInt8) -> UInt32 {
    let alpha = UInt32(a)
    let blue = UInt32(b) * alpha / 255
    let green = UInt32(g) * alpha / 255
    let red = UInt32(r) * alpha / 255
    return blue | (green << 8) | (red << 16) | (alpha << 24)
}

func fade(_ color: UInt32, _ coverage: Double) -> UInt32 {
    let scale = UInt32(max(0, min(1, coverage)) * 255)
    func channel(_ value: UInt32) -> UInt32 { value * scale / 255 }
    return channel(color & 0xFF)
        | (channel((color >> 8) & 0xFF) << 8)
        | (channel((color >> 16) & 0xFF) << 16)
        | (channel((color >> 24) & 0xFF) << 24)
}

func over(_ dst: UInt32, _ src: UInt32) -> UInt32 {
    let sa = Int(src >> 24)
    if sa <= 0 { return dst }
    if sa >= 255 { return src }
    let inv = UInt32(255 - sa)
    func channel(_ source: UInt32, _ destination: UInt32) -> UInt32 {
        source + (destination * inv + 127) / 255
    }
    let blue = channel(src & 0xFF, dst & 0xFF)
    let green = channel((src >> 8) & 0xFF, (dst >> 8) & 0xFF)
    let red = channel((src >> 16) & 0xFF, (dst >> 16) & 0xFF)
    let alpha = channel((src >> 24) & 0xFF, (dst >> 24) & 0xFF)
    return blue | (green << 8) | (red << 16) | (alpha << 24)
}

func circle(distance: Double, radius: Double) -> Double {
    let inner = radius - 1
    if distance <= inner { return 1 }
    if distance >= radius { return 0 }
    return radius - distance
}

func roundRect(x: Double, y: Double, width: Double, height: Double, radius: Double, inset: Double) -> Double {
    let left = inset
    let top = inset
    let right = width - inset
    let bottom = height - inset
    let px = min(max(x, left), right)
    let py = min(max(y, top), bottom)
    let cx = min(max(px, left + radius), right - radius)
    let cy = min(max(py, top + radius), bottom - radius)
    let distance = hypot(px - cx, py - cy)
    if distance <= radius - 1 { return 1 }
    if distance >= radius { return 0 }
    return radius - distance
}

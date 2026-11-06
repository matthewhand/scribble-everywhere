import Foundation
import WinSDK
import PalimpsestCore

/// Captures a screen rect with GDI (BitBlt from the screen DC), excluding our
/// own windows the same way the macOS capturer does - by hiding them briefly.
/// The ink is composited from the stroke model afterwards, not read from the
/// screen, so the preview ink is never baked in twice.
struct WinScreenCapturer: PalimpsestCore.ScreenCapturer {
    struct CapturedImage {
        let image: ImageBuffer
        /// Physical screen-pixel origin of the captured image.
        let origin: Point
        /// Display scale used for ink width, not for pixel coordinates.
        let scale: Double
    }

    func capture(rect: Rect) async throws -> ImageBuffer {
        try captureNow(rect: rect)
    }

    func captureNow(rect: Rect) throws -> ImageBuffer {
        try captureWithGeometry(rect: rect).image
    }

    func captureWithGeometry(rect: Rect) throws -> CapturedImage {
        let plan = try planFor(rect: rect)
        guard let buffer = captureSync(plan: plan) else {
            throw ScreenCapturerError(message: "BitBlt capture failed")
        }
        return CapturedImage(image: buffer,
                             origin: Point(x: Double(plan.screenRect.left), y: Double(plan.screenRect.top)),
                             scale: plan.scale)
    }

    private struct Plan {
        var screenRect: RECT
        var pixelWidth: Int
        var pixelHeight: Int
        var scale: Double
    }

    private func planFor(rect: Rect) throws -> Plan {
        let display = WinDisplays.display(containing: Point(x: rect.midX, y: rect.midY))
        guard let display else {
            throw ScreenCapturerError(message: "No display contains the target region")
        }
        // Per-monitor v2 makes rcMonitor and the window rect physical pixels.
        // Core's scale turns points into pixels; here they are already pixels.
        guard let plan = CaptureGeometry.plan(window: rect, display: display.frame, scale: 1) else {
            throw ScreenCapturerError(message: "Target region is empty")
        }
        return Plan(
            screenRect: RECT(
                left: Int32(display.frame.minX + plan.sourceRect.minX),
                top: Int32(display.frame.minY + plan.sourceRect.minY),
                right: Int32(display.frame.minX + plan.sourceRect.maxX),
                bottom: Int32(display.frame.minY + plan.sourceRect.maxY)
            ),
            pixelWidth: plan.pixelWidth,
            pixelHeight: plan.pixelHeight,
            scale: display.scale
        )
    }

    private func captureSync(plan: Plan) -> ImageBuffer? {
        let screenDC = GetDC(nil)
        guard let screenDC else { return nil }
        defer { ReleaseDC(nil, screenDC) }

        let memDC = CreateCompatibleDC(screenDC)
        guard let memDC else { return nil }
        defer { DeleteDC(memDC) }

        let bitmap = CreateCompatibleBitmap(screenDC, Int32(plan.pixelWidth), Int32(plan.pixelHeight))
        guard let bitmap else { return nil }
        defer { DeleteObject(bitmap) }

        let oldBitmap = SelectObject(memDC, bitmap)

        // Include layered application windows in the screenshot. Our own
        // overlay and palette are hidden and the compositor is flushed by the
        // controller before this call, so preview ink is not baked in.
        let captureLayeredWindows: DWORD = 0x40000000 // CAPTUREBLT
        let ok = BitBlt(
            memDC, 0, 0, Int32(plan.pixelWidth), Int32(plan.pixelHeight),
            screenDC, plan.screenRect.left, plan.screenRect.top, DWORD(SRCCOPY) | captureLayeredWindows
        )
        // GetDIBits requires that the bitmap is not selected into any DC.
        _ = SelectObject(memDC, oldBitmap)
        guard ok else { return nil }

        return pixelsFrom(bitmap: bitmap, memDC: memDC, width: plan.pixelWidth, height: plan.pixelHeight)
    }

    private func pixelsFrom(bitmap: HBITMAP, memDC: HDC, width: Int, height: Int) -> ImageBuffer? {
        var info = BITMAPINFO()
        info.bmiHeader.biSize = UINT32(MemoryLayout<BITMAPINFOHEADER>.size)
        info.bmiHeader.biWidth = Int32(width)
        info.bmiHeader.biHeight = -Int32(height) // top-down
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        info.bmiHeader.biCompression = UInt32(BI_RGB)

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ok = GetDIBits(
            memDC, bitmap, 0, UINT32(height), &pixels,
            &info, DWORD(DIB_RGB_COLORS)
        )
        guard Int(ok) == height else { return nil }

        // BGRA -> RGBA (keep alpha opaque; screen capture has no alpha).
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let blue = pixels[index]
            pixels[index] = pixels[index + 2]   // R
            pixels[index + 2] = blue            // B
            pixels[index + 3] = 255             // A
        }
        return ImageBuffer(width: width, height: height, pixels: pixels)
    }
}

struct ScreenCapturerError: Error {
    var message: String
}

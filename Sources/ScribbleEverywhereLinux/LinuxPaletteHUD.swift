import Foundation
import PalimpsestCore
import CPalimpsestLinux

enum LinuxFloatingPalette: String {
    case none
    case topLeft
    case topRight

    init(stored: String?) {
        switch stored ?? "" {
        case "none": self = .none
        case "topLeft", "top-left": self = .topLeft
        case "topRight", "top-right": self = .topRight
        default: self = .topRight
        }
    }

    init?(command: String) {
        switch command {
        case "none": self = .none
        case "topLeft", "top-left": self = .topLeft
        case "topRight", "top-right": self = .topRight
        default: return nil
        }
    }
}

enum LinuxPaletteAction: Equatable {
    case select(Int)
    case clear
    case save
}

/// Overlay-local logical layout for the floating colour capsule.
struct LinuxPaletteHUD {
    var frame: Rect
    var swatches: [Rect]
    var clear: Rect
    var save: Rect

    static func make(palette: Palette, overlay: palimpsest_output_info, position: LinuxFloatingPalette) -> LinuxPaletteHUD? {
        guard position != .none, overlay.logical_width > 0, overlay.logical_height > 0 else { return nil }
        let count = max(palette.colors.count, 1)
        let width = Double(count) * 34 + 72
        let height: Double = 48
        let x: Double
        switch position {
        case .none:
            return nil
        case .topLeft:
            x = 16
        case .topRight:
            x = max(16, Double(overlay.logical_width) - width - 16)
        }
        let y: Double = 12
        var swatches: [Rect] = []
        for index in 0..<count {
            swatches.append(Rect(x: x + 10 + Double(index) * 34, y: y + 11, width: 26, height: 26))
        }
        let clear = Rect(x: x + width - 54, y: y + 13, width: 22, height: 22)
        let save = Rect(x: x + width - 32, y: y + 13, width: 22, height: 22)
        return LinuxPaletteHUD(
            frame: Rect(x: x, y: y, width: width, height: height),
            swatches: swatches,
            clear: clear,
            save: save
        )
    }

    func hit(_ local: Point) -> LinuxPaletteAction? {
        guard frame.contains(local) else { return nil }
        for (index, swatch) in swatches.enumerated() where swatch.contains(local) {
            return .select(index)
        }
        if clear.contains(local) { return .clear }
        if save.contains(local) { return .save }
        return nil
    }

    func paint(palette: Palette, onto image: inout ImageBuffer, overlay: palimpsest_output_info) {
        let scaleX = overlay.logical_width > 0 ? Double(overlay.buffer_width) / Double(overlay.logical_width) : Double(max(overlay.scale, 1))
        let scaleY = overlay.logical_height > 0 ? Double(overlay.buffer_height) / Double(overlay.logical_height) : scaleX
        fillRoundRect(&image, rect: frame, radius: 24, color: RGBA(r: 22, g: 22, b: 24, a: 210), scaleX: scaleX, scaleY: scaleY)
        for (index, swatch) in swatches.enumerated() {
            let color = index < palette.colors.count ? palette.colors[index] : .red
            fillCircle(&image, rect: swatch, color: color, scaleX: scaleX, scaleY: scaleY)
            let ring = index == palette.index ? RGBA(r: 255, g: 255, b: 255, a: 255) : RGBA(r: 255, g: 255, b: 255, a: 160)
            strokeCircle(&image, rect: swatch, color: ring, width: index == palette.index ? 3 : 1, scaleX: scaleX, scaleY: scaleY)
        }
        strokeRoundRect(&image, rect: clear, radius: 6, color: RGBA(r: 255, g: 255, b: 255, a: 200), scaleX: scaleX, scaleY: scaleY)
        drawClearMark(&image, rect: clear, color: RGBA(r: 255, g: 255, b: 255, a: 230), scaleX: scaleX, scaleY: scaleY)
        strokeRoundRect(&image, rect: save, radius: 6, color: RGBA(r: 255, g: 255, b: 255, a: 200), scaleX: scaleX, scaleY: scaleY)
        drawSaveMark(&image, rect: save, color: RGBA(r: 255, g: 255, b: 255, a: 230), scaleX: scaleX, scaleY: scaleY)
    }
}

enum LinuxColourNames {
    private static let known: [(RGBA, String)] = [
        (.red, "Red"),
        (.blue, "Blue"),
        (RGBA(r: 0, g: 114, b: 255), "Blue"),
        (.green, "Green"),
        (RGBA(r: 255, g: 149, b: 0), "Orange"),
        (RGBA(r: 175, g: 82, b: 222), "Purple"),
        (RGBA(r: 255, g: 214, b: 10), "Yellow"),
        (RGBA(r: 90, g: 200, b: 250), "Cyan"),
        (RGBA(r: 255, g: 45, b: 85), "Pink"),
        (RGBA(r: 255, g: 255, b: 255), "White"),
        (RGBA(r: 0, g: 0, b: 0), "Black")
    ]

    static func name(for color: RGBA) -> String {
        known.first { $0.0 == color }?.1 ?? color.hex
    }
}

private func fillRoundRect(_ image: inout ImageBuffer, rect: Rect, radius: Double, color: RGBA, scaleX: Double, scaleY: Double) {
    let minX = Int((rect.minX * scaleX).rounded(.down))
    let minY = Int((rect.minY * scaleY).rounded(.down))
    let maxX = Int((rect.maxX * scaleX).rounded(.up))
    let maxY = Int((rect.maxY * scaleY).rounded(.up))
    let rx = radius * scaleX
    let ry = radius * scaleY
    for y in minY..<maxY {
        for x in minX..<maxX {
            let px = Double(x) + 0.5
            let py = Double(y) + 0.5
            if insideRoundRect(px, py, minX: Double(minX), minY: Double(minY), maxX: Double(maxX), maxY: Double(maxY), rx: rx, ry: ry) {
                blend(&image, x: x, y: y, color: color)
            }
        }
    }
}

private func strokeRoundRect(_ image: inout ImageBuffer, rect: Rect, radius: Double, color: RGBA, scaleX: Double, scaleY: Double) {
    let inset = Rect(x: rect.minX + 1, y: rect.minY + 1, width: max(rect.width - 2, 1), height: max(rect.height - 2, 1))
    fillRoundRect(&image, rect: rect, radius: radius, color: color, scaleX: scaleX, scaleY: scaleY)
    fillRoundRect(&image, rect: inset, radius: max(radius - 1, 0), color: RGBA(r: 22, g: 22, b: 24, a: 210), scaleX: scaleX, scaleY: scaleY)
}

private func fillCircle(_ image: inout ImageBuffer, rect: Rect, color: RGBA, scaleX: Double, scaleY: Double) {
    let cx = rect.midX * scaleX
    let cy = rect.midY * scaleY
    let rx = (rect.width / 2) * scaleX
    let ry = (rect.height / 2) * scaleY
    let minX = Int((rect.minX * scaleX).rounded(.down))
    let minY = Int((rect.minY * scaleY).rounded(.down))
    let maxX = Int((rect.maxX * scaleX).rounded(.up))
    let maxY = Int((rect.maxY * scaleY).rounded(.up))
    let rx2 = max(rx * rx, 1)
    let ry2 = max(ry * ry, 1)
    for y in minY..<maxY {
        for x in minX..<maxX {
            let dx = Double(x) + 0.5 - cx
            let dy = Double(y) + 0.5 - cy
            if (dx * dx) / rx2 + (dy * dy) / ry2 <= 1 {
                blend(&image, x: x, y: y, color: color)
            }
        }
    }
}

private func strokeCircle(_ image: inout ImageBuffer, rect: Rect, color: RGBA, width: Double, scaleX: Double, scaleY: Double) {
    let cx = rect.midX * scaleX
    let cy = rect.midY * scaleY
    let rx = (rect.width / 2) * scaleX
    let ry = (rect.height / 2) * scaleY
    let innerX = max(rx - width * scaleX, 0)
    let innerY = max(ry - width * scaleY, 0)
    let minX = Int((rect.minX * scaleX).rounded(.down)) - 1
    let minY = Int((rect.minY * scaleY).rounded(.down)) - 1
    let maxX = Int((rect.maxX * scaleX).rounded(.up)) + 1
    let maxY = Int((rect.maxY * scaleY).rounded(.up)) + 1
    let rx2 = max(rx * rx, 1)
    let ry2 = max(ry * ry, 1)
    let ix2 = max(innerX * innerX, 0.25)
    let iy2 = max(innerY * innerY, 0.25)
    for y in minY..<maxY {
        for x in minX..<maxX {
            let dx = Double(x) + 0.5 - cx
            let dy = Double(y) + 0.5 - cy
            let outer = (dx * dx) / rx2 + (dy * dy) / ry2
            let inner = (dx * dx) / ix2 + (dy * dy) / iy2
            if outer <= 1 && inner >= 1 {
                blend(&image, x: x, y: y, color: color)
            }
        }
    }
}

private func drawClearMark(_ image: inout ImageBuffer, rect: Rect, color: RGBA, scaleX: Double, scaleY: Double) {
    let inset = 5.0
    strokeLine(
        &image,
        from: Point(x: rect.minX + inset, y: rect.minY + inset),
        to: Point(x: rect.maxX - inset, y: rect.maxY - inset),
        color: color, scaleX: scaleX, scaleY: scaleY
    )
    strokeLine(
        &image,
        from: Point(x: rect.maxX - inset, y: rect.minY + inset),
        to: Point(x: rect.minX + inset, y: rect.maxY - inset),
        color: color, scaleX: scaleX, scaleY: scaleY
    )
}

private func drawSaveMark(_ image: inout ImageBuffer, rect: Rect, color: RGBA, scaleX: Double, scaleY: Double) {
    let shutter = Rect(x: rect.midX - 4, y: rect.minY + 3.5, width: 8, height: 4)
    fillRoundRect(&image, rect: shutter, radius: 1, color: color, scaleX: scaleX, scaleY: scaleY)
    let label = Rect(x: rect.minX + 5, y: rect.maxY - 8, width: max(rect.width - 10, 1), height: 4)
    fillRoundRect(&image, rect: label, radius: 1, color: color, scaleX: scaleX, scaleY: scaleY)
}

private func strokeLine(_ image: inout ImageBuffer, from a: Point, to b: Point, color: RGBA, scaleX: Double, scaleY: Double) {
    var x0 = Int((a.x * scaleX).rounded())
    var y0 = Int((a.y * scaleY).rounded())
    let x1 = Int((b.x * scaleX).rounded())
    let y1 = Int((b.y * scaleY).rounded())
    let dx = abs(x1 - x0)
    let dy = -abs(y1 - y0)
    let sx = x0 < x1 ? 1 : -1
    let sy = y0 < y1 ? 1 : -1
    var err = dx + dy
    while true {
        blend(&image, x: x0, y: y0, color: color)
        blend(&image, x: x0 + 1, y: y0, color: color)
        if x0 == x1 && y0 == y1 { break }
        let e2 = 2 * err
        if e2 >= dy {
            err += dy
            x0 += sx
        }
        if e2 <= dx {
            err += dx
            y0 += sy
        }
    }
}

private func insideRoundRect(_ x: Double, _ y: Double, minX: Double, minY: Double, maxX: Double, maxY: Double, rx: Double, ry: Double) -> Bool {
    let cx: Double
    let cy: Double
    if x < minX + rx { cx = minX + rx }
    else if x > maxX - rx { cx = maxX - rx }
    else { cx = x }
    if y < minY + ry { cy = minY + ry }
    else if y > maxY - ry { cy = maxY - ry }
    else { cy = y }
    if cx == x || cy == y { return x >= minX && x < maxX && y >= minY && y < maxY }
    let dx = (x - cx) / max(rx, 1)
    let dy = (y - cy) / max(ry, 1)
    return dx * dx + dy * dy <= 1
}

private func blend(_ image: inout ImageBuffer, x: Int, y: Int, color: RGBA) {
    let existing = image[x, y]
    let sourceAlpha = Double(color.a) / 255
    let destinationAlpha = Double(existing.a) / 255
    let inverse = 1 - sourceAlpha
    let outputAlpha = sourceAlpha + destinationAlpha * inverse
    guard outputAlpha > 0 else { return }
    image[x, y] = RGBA(
        r: UInt8(((Double(color.r) * sourceAlpha + Double(existing.r) * destinationAlpha * inverse) / outputAlpha).rounded()),
        g: UInt8(((Double(color.g) * sourceAlpha + Double(existing.g) * destinationAlpha * inverse) / outputAlpha).rounded()),
        b: UInt8(((Double(color.b) * sourceAlpha + Double(existing.b) * destinationAlpha * inverse) / outputAlpha).rounded()),
        a: UInt8((outputAlpha * 255).rounded())
    )
}

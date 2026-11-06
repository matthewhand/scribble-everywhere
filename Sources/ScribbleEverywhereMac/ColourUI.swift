import AppKit
import SwiftUI
import PalimpsestCore

/// Human-readable names for the built-in colours, falling back to hex for
/// custom ones. Used by the HUD and the menus.
enum ColourNames {
    private static let known: [(RGBA, String)] = [
        (.red, "Red"),
        (.blue, "Blue"),
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

extension RGBA {
    /// Reads a SwiftUI `Color` back into the SRGB byte space `Stroke` uses.
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .clear
        self.init(
            r: UInt8((ns.redComponent * 255).rounded()),
            g: UInt8((ns.greenComponent * 255).rounded()),
            b: UInt8((ns.blueComponent * 255).rounded()),
            a: UInt8((ns.alphaComponent * 255).rounded())
        )
    }
}

extension Color {
    init(_ rgba: RGBA) {
        self.init(
            .sRGB,
            red: Double(rgba.r) / 255,
            green: Double(rgba.g) / 255,
            blue: Double(rgba.b) / 255,
            opacity: Double(rgba.a) / 255
        )
    }
}

extension NSImage {
    /// A small filled circle used as a menu-item image for a palette colour.
    static func swatch(_ rgba: RGBA, size: CGFloat = 12) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let rect = NSRect(x: 0.5, y: 0.5, width: size - 1, height: size - 1)
        let path = NSBezierPath(ovalIn: rect)
        NSColor(
            srgbRed: CGFloat(rgba.r) / 255,
            green: CGFloat(rgba.g) / 255,
            blue: CGFloat(rgba.b) / 255,
            alpha: CGFloat(rgba.a) / 255
        ).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        image.unlockFocus()
        return image
    }
}

import AppKit
import PalimpsestCore

enum ScreenGeometry {
    /// Displays in top-left-origin global coordinates with pixel scale.
    static func displays() -> [DisplayFrame] {
        guard let primary = NSScreen.screens.first else { return [] }
        let primaryMaxY = primary.frame.maxY

        return NSScreen.screens.map { screen in
            let frame = screen.frame
            let globalFrame = CoordinateConversion.topLeftRect(
                fromBottomLeft: Rect(
                    x: frame.origin.x,
                    y: frame.origin.y,
                    width: frame.width,
                    height: frame.height
                ),
                primaryMaxY: primaryMaxY
            )
            let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return DisplayFrame(id: number, frame: globalFrame, scale: Double(screen.backingScaleFactor))
        }
    }

    /// Union of all screens' visible areas (menu bar / Dock excluded),
    /// top-left origin.
    static func unionVisibleFrame() -> Rect {
        guard let primary = NSScreen.screens.first else { return Rect(x: 0, y: 0, width: 0, height: 0) }
        let primaryMaxY = primary.frame.maxY

        let rects = NSScreen.screens.map { screen -> Rect in
            let visible = screen.visibleFrame
            return CoordinateConversion.topLeftRect(
                fromBottomLeft: Rect(
                    x: visible.origin.x,
                    y: visible.origin.y,
                    width: visible.width,
                    height: visible.height
                ),
                primaryMaxY: primaryMaxY
            )
        }

        let minX = rects.map(\.minX).min() ?? 0
        let minY = rects.map(\.minY).min() ?? 0
        let maxX = rects.map(\.maxX).max() ?? 0
        let maxY = rects.map(\.maxY).max() ?? 0
        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Converts a top-left-origin global rect back into AppKit's bottom-left
    /// window coordinates.
    static func cocoaFrame(fromTopLeft rect: Rect) -> NSRect {
        guard let primary = NSScreen.screens.first else {
            return NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        }
        let primaryMaxY = primary.frame.maxY
        return NSRect(
            x: rect.minX,
            y: primaryMaxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}

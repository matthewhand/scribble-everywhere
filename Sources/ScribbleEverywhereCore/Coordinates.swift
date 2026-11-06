import Foundation

/// Conversions between the two global screen spaces that macOS shells deal with:
/// Cocoa's bottom-left-origin space (NSScreen) and the top-left-origin space used
/// by window frames and capture APIs. Kept platform-free so it can be tested and
/// reused.
public enum CoordinateConversion {
    /// `primaryMaxY` is the top edge of the primary display in Cocoa coordinates
    /// (usually its height).
    public static func topLeftPoint(fromBottomLeft point: Point, primaryMaxY: Double) -> Point {
        Point(x: point.x, y: primaryMaxY - point.y)
    }

    public static func topLeftRect(fromBottomLeft rect: Rect, primaryMaxY: Double) -> Rect {
        Rect(x: rect.minX, y: primaryMaxY - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// A display in top-left-origin global coordinates, with its pixel scale.
public struct DisplayFrame: Equatable, Sendable {
    public var id: UInt32
    public var frame: Rect
    public var scale: Double

    public init(id: UInt32, frame: Rect, scale: Double) {
        self.id = id
        self.frame = frame
        self.scale = scale
    }
}

public enum DisplayLookup {
    public static func display(containing point: Point, in displays: [DisplayFrame]) -> DisplayFrame? {
        displays.first { $0.frame.contains(point) }
    }

    /// The display a window should be annotated on: the one containing the
    /// window's centre, falling back to the display that overlaps it most, then
    /// to the first display when nothing overlaps (e.g. an off-screen window).
    ///
    /// A window can straddle two displays; centre-containing matches the display
    /// the user is looking at, and the most-overlapping fallback keeps the
    /// overlay on the display that actually shows most of the window.
    public static func display(covering window: Rect, in displays: [DisplayFrame]) -> DisplayFrame? {
        guard !displays.isEmpty else { return nil }
        let centre = Point(x: window.midX, y: window.midY)
        if let containing = display(containing: centre, in: displays) {
            return containing
        }

        var best: (display: DisplayFrame, area: Double)?
        for display in displays {
            guard let overlap = window.intersection(display.frame) else { continue }
            let area = overlap.width * overlap.height
            if best == nil || area > best!.area {
                best = (display, area)
            }
        }
        return best?.display ?? displays.first
    }
}

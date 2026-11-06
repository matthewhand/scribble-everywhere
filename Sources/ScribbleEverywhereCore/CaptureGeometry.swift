import Foundation

/// Plans a display-relative capture rectangle and its pixel dimensions.
public struct CapturePlan: Equatable, Sendable {
    public var sourceRect: Rect
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(sourceRect: Rect, pixelWidth: Int, pixelHeight: Int) {
        self.sourceRect = sourceRect
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public enum CaptureGeometry {
    /// Clamp `window` (top-left global) to `display` (top-left global) and scale
    /// the result to pixels. Returns nil when the clamped region is degenerate.
    public static func plan(window: Rect, display: Rect, scale: Double) -> CapturePlan? {
        guard !window.isEmpty, !display.isEmpty, scale > 0 else { return nil }

        // Intersect the window with the display, so a window that overhangs an
        // edge is captured as its on-display portion (display-local, points).
        let minX = Swift.max(window.minX, display.minX)
        let minY = Swift.max(window.minY, display.minY)
        let maxX = Swift.min(window.maxX, display.maxX)
        let maxY = Swift.min(window.maxY, display.maxY)
        let width = maxX - minX
        let height = maxY - minY
        guard width > 1, height > 1 else { return nil }

        return CapturePlan(
            sourceRect: Rect(x: minX - display.minX, y: minY - display.minY, width: width, height: height),
            pixelWidth: Swift.max(Int((width * scale).rounded()), 1),
            pixelHeight: Swift.max(Int((height * scale).rounded()), 1)
        )
    }
}

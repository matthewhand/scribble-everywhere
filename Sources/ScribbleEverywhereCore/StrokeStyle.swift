import Foundation

/// Maps pointer pressure to stroke width.
///
/// Mouse and trackpad strokes are always `fixedWidth`. Only genuine tablet events
/// (`isTablet == true`) use pressure, and a flat `0.0` from a mislabelled device
/// still falls back to `fixedWidth` so the stroke is never invisible.
public struct StrokeStyle: Equatable, Sendable {
    public var fixedWidth: Double
    public var minWidth: Double
    public var maxWidth: Double

    public init(fixedWidth: Double, minWidth: Double, maxWidth: Double) {
        self.fixedWidth = fixedWidth
        self.minWidth = minWidth
        self.maxWidth = maxWidth
    }

    public static let standard = StrokeStyle(fixedWidth: 4, minWidth: 2, maxWidth: 20)

    /// Pressure below this is treated as "no pressure" (unreliable / flat 0.0).
    public static let pressureFloor = 0.02

    public func width(pressure: Double, isTablet: Bool) -> Double {
        guard isTablet, pressure > StrokeStyle.pressureFloor else { return fixedWidth }
        let clamped = Swift.min(Swift.max(pressure, 0), 1)
        return minWidth + (maxWidth - minWidth) * clamped
    }
}

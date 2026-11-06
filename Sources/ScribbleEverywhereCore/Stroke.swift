import Foundation

public struct RGBA: Equatable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let red = RGBA(r: 255, g: 59, b: 48)
    public static let blue = RGBA(r: 0, g: 122, b: 255)
    public static let green = RGBA(r: 52, g: 199, b: 89)
    public static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)

    /// `#RRGGBB` or `#RRGGBBAA`, as used for persistence.
    public var hex: String {
        String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }

    public init?(hex: String) {
        let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard value.count == 6 || value.count == 8, let number = UInt32(value, radix: 16) else { return nil }
        if value.count == 6 {
            self.init(
                r: UInt8((number >> 16) & 0xFF),
                g: UInt8((number >> 8) & 0xFF),
                b: UInt8(number & 0xFF)
            )
        } else {
            self.init(
                r: UInt8((number >> 24) & 0xFF),
                g: UInt8((number >> 16) & 0xFF),
                b: UInt8((number >> 8) & 0xFF),
                a: UInt8(number & 0xFF)
            )
        }
    }
}

public struct StrokePoint: Equatable, Sendable {
    public var location: Point
    public var pressure: Double
    public var isTablet: Bool

    public init(location: Point, pressure: Double, isTablet: Bool) {
        self.location = location
        self.pressure = pressure
        self.isTablet = isTablet
    }
}

public struct Stroke: Equatable, Sendable {
    public private(set) var points: [StrokePoint]
    public var ink: RGBA

    public init(ink: RGBA, first: StrokePoint) {
        self.ink = ink
        self.points = [first]
    }

    public init(ink: RGBA, points: [StrokePoint]) {
        self.ink = ink
        self.points = points
    }

    public mutating func append(_ point: StrokePoint) {
        points.append(point)
    }
}

/// Holds the finished strokes plus the in-progress one, and owns undo/clear.
/// Platform-free: the macOS view renders from this, other shells can too.
public final class StrokeCanvas {
    public let style: StrokeStyle
    public var ink: RGBA

    public private(set) var strokes: [Stroke] = []
    public private(set) var current: Stroke?

    public init(style: StrokeStyle = .standard, ink: RGBA = .red) {
        self.style = style
        self.ink = ink
    }

    public var hasContent: Bool { !strokes.isEmpty || current != nil }

    /// Finished strokes plus the in-progress one; used by the menu for Undo/Clear.
    public var strokeCount: Int { strokes.count + (current == nil ? 0 : 1) }

    public func begin(at point: StrokePoint) {
        current = Stroke(ink: ink, first: point)
    }

    public func extend(to point: StrokePoint) {
        guard current != nil else { return }
        current?.append(point)
    }

    public func end(at point: StrokePoint) {
        guard var stroke = current else { return }
        stroke.append(point)
        strokes.append(stroke)
        current = nil
    }

    public func undo() {
        if current != nil {
            current = nil
        } else if !strokes.isEmpty {
            strokes.removeLast()
        }
    }

    public func clear() {
        strokes.removeAll()
        current = nil
    }

    /// Every stroke to render, finished first, in-progress last.
    public func allStrokes() -> [Stroke] {
        var all = strokes
        if let current { all.append(current) }
        return all
    }
}

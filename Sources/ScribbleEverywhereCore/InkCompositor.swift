import Foundation

/// Rasterises ink onto an image buffer. On macOS the live overlay is composited
/// by the window server, but a portable compositor is useful for non-macOS shells
/// (which must blend ink into a captured image themselves) and for testing.
public protocol InkCompositor {
    func composite(strokes: [Stroke], style: StrokeStyle, onto image: ImageBuffer) -> ImageBuffer
}

public struct BufferInkCompositor: InkCompositor {
    public init() {}

    public func composite(strokes: [Stroke], style: StrokeStyle, onto image: ImageBuffer) -> ImageBuffer {
        var output = image
        for stroke in strokes {
            let points = stroke.points
            guard !points.isEmpty, stroke.ink.a != 0 else { continue }

            // A segment is drawn with overlapping stamps. Blend translucent ink
            // once per pixel per stroke, not once per stamp, so opacity does
            // not depend on sampling density or pointer speed. Opaque strokes
            // do not need a coverage map.
            let pixelCount = image.width * image.height
            var coverage: [UInt8] = stroke.ink.a == 255
                ? [] : [UInt8](repeating: 0, count: pixelCount / 8 + (pixelCount % 8 == 0 ? 0 : 1))

            if points.count == 1 {
                let width = style.width(pressure: points[0].pressure, isTablet: points[0].isTablet)
                stamp(&output, at: points[0].location, radius: width / 2, color: stroke.ink, coverage: &coverage)
                continue
            }

            for index in 1..<points.count {
                let a = points[index - 1]
                let b = points[index]
                let width = (style.width(pressure: a.pressure, isTablet: a.isTablet)
                    + style.width(pressure: b.pressure, isTablet: b.isTablet)) / 2
                drawSegment(&output, from: a.location, to: b.location, radius: width / 2, color: stroke.ink, coverage: &coverage)
            }
        }
        return output
    }

    private func drawSegment(_ image: inout ImageBuffer, from a: Point, to b: Point, radius: Double, color: RGBA, coverage: inout [UInt8]) {
        guard a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite, radius.isFinite else { return }
        let dx = b.x - a.x
        let dy = b.y - a.y
        guard dx.isFinite, dy.isFinite else { return }
        // Only sample the part close enough to touch the image. Long strokes
        // outside the captured window must not take time proportional to their
        // off-screen length, or overflow when converted to a step count.
        let r = Swift.max(radius, 0.5)
        var start = 0.0, end = 1.0
        func clip(_ origin: Double, _ delta: Double, _ lower: Double, _ upper: Double) -> Bool {
            if delta == 0 { return origin >= lower && origin <= upper }
            let t0 = (lower - origin) / delta
            let t1 = (upper - origin) / delta
            start = Swift.max(start, Swift.min(t0, t1))
            end = Swift.min(end, Swift.max(t0, t1))
            return start <= end
        }
        guard clip(a.x, dx, -r, Double(image.width) + r),
              clip(a.y, dy, -r, Double(image.height) + r) else { return }
        let clippedA = Point(x: a.x + dx * start, y: a.y + dy * start)
        let clippedB = Point(x: a.x + dx * end, y: a.y + dy * end)
        let clippedDX = clippedB.x - clippedA.x
        let clippedDY = clippedB.y - clippedA.y
        let distance = Swift.max(abs(clippedDX), abs(clippedDY))
        guard distance.isFinite, distance < Double(Int.max / 2) else { return }
        let steps = Swift.max(Int(distance * 2), 1)
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            let point = Point(x: clippedA.x + clippedDX * t, y: clippedA.y + clippedDY * t)
            stamp(&image, at: point, radius: radius, color: color, coverage: &coverage)
        }
    }

    private func stamp(_ image: inout ImageBuffer, at center: Point, radius: Double, color: RGBA, coverage: inout [UInt8]) {
        guard center.x.isFinite, center.y.isFinite, radius.isFinite else { return }
        let r = Swift.max(radius, 0.5)
        guard center.x + r >= 0, center.y + r >= 0,
              center.x - r < Double(image.width), center.y - r < Double(image.height) else { return }
        let minX = Int(Swift.max(0, (center.x - r).rounded(.down)))
        let maxX = Int(Swift.min(Double(image.width - 1), (center.x + r).rounded(.up)))
        let minY = Int(Swift.max(0, (center.y - r).rounded(.down)))
        let maxY = Int(Swift.min(Double(image.height - 1), (center.y + r).rounded(.up)))
        let rSquared = r * r
        for y in minY...maxY {
            for x in minX...maxX {
                let cx = Double(x) + 0.5 - center.x
                let cy = Double(y) + 0.5 - center.y
                if cx * cx + cy * cy <= rSquared {
                    if !coverage.isEmpty {
                        let pixel = y * image.width + x
                        let byte = pixel / 8
                        let bit = UInt8(1 << (pixel % 8))
                        if coverage[byte] & bit != 0 { continue }
                        coverage[byte] |= bit
                    }
                    blend(&image, x: x, y: y, color: color)
                }
            }
        }
    }

    private func blend(_ image: inout ImageBuffer, x: Int, y: Int, color: RGBA) {
        guard x >= 0, x < image.width, y >= 0, y < image.height else { return }
        let existing = image[x, y]
        let sourceAlpha = Double(color.a) / 255
        let destinationAlpha = Double(existing.a) / 255
        let inverse = 1 - sourceAlpha
        let outputAlpha = sourceAlpha + destinationAlpha * inverse
        guard outputAlpha > 0 else {
            image[x, y] = .clear
            return
        }
        image[x, y] = RGBA(
            r: UInt8(((Double(color.r) * sourceAlpha + Double(existing.r) * destinationAlpha * inverse) / outputAlpha).rounded()),
            g: UInt8(((Double(color.g) * sourceAlpha + Double(existing.g) * destinationAlpha * inverse) / outputAlpha).rounded()),
            b: UInt8(((Double(color.b) * sourceAlpha + Double(existing.b) * destinationAlpha * inverse) / outputAlpha).rounded()),
            a: UInt8((outputAlpha * 255).rounded())
        )
    }
}

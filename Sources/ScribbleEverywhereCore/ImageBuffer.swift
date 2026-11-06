import Foundation

/// A simple top-left-origin RGBA8 image buffer. Foundation only, so it works on
/// every Swift platform; the macOS shell converts to/from `CGImage` at the edges.
public struct ImageBuffer: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public private(set) var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width > 0 && height > 0, "image must be non-empty")
        precondition(pixels.count == width * height * 4, "pixel buffer size mismatch")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: RGBA = .clear) {
        self.init(width: width, height: height, pixels: [UInt8](repeating: 0, count: width * height * 4))
        for y in 0..<height {
            for x in 0..<width {
                self[x, y] = fill
            }
        }
    }

    public subscript(x: Int, y: Int) -> RGBA {
        get {
            guard x >= 0, x < width, y >= 0, y < height else { return .clear }
            let i = (y * width + x) * 4
            return RGBA(r: pixels[i], g: pixels[i + 1], b: pixels[i + 2], a: pixels[i + 3])
        }
        set {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            let i = (y * width + x) * 4
            pixels[i] = newValue.r
            pixels[i + 1] = newValue.g
            pixels[i + 2] = newValue.b
            pixels[i + 3] = newValue.a
        }
    }

    public func data() -> Data {
        Data(pixels)
    }

    public func flattened(on background: RGBA = RGBA(r: 226, g: 226, b: 222)) -> ImageBuffer {
        var output = self
        for y in 0..<height {
            for x in 0..<width {
                let pixel = self[x, y]
                let alpha = Double(pixel.a) / 255
                let inverse = 1 - alpha
                output[x, y] = RGBA(
                    r: UInt8((Double(pixel.r) * alpha + Double(background.r) * inverse).rounded()),
                    g: UInt8((Double(pixel.g) * alpha + Double(background.g) * inverse).rounded()),
                    b: UInt8((Double(pixel.b) * alpha + Double(background.b) * inverse).rounded())
                )
            }
        }
        return output
    }
}

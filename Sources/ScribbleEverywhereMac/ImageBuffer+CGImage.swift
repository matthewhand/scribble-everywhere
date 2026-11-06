import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PalimpsestCore

extension ImageBuffer {
    /// Decodes a `CGImage` into an RGBA8 buffer (top-left origin).
    static func from(_ cgImage: CGImage) -> ImageBuffer? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[index + 3])
            guard alpha > 0, alpha < 255 else { continue }
            pixels[index] = UInt8(min((Int(pixels[index]) * 255 + alpha / 2) / alpha, 255))
            pixels[index + 1] = UInt8(min((Int(pixels[index + 1]) * 255 + alpha / 2) / alpha, 255))
            pixels[index + 2] = UInt8(min((Int(pixels[index + 2]) * 255 + alpha / 2) / alpha, 255))
        }
        return ImageBuffer(width: width, height: height, pixels: pixels)
    }

    func cgImage() -> CGImage? {
        var premultiplied = pixels
        for index in stride(from: 0, to: premultiplied.count, by: 4) {
            let alpha = Int(premultiplied[index + 3])
            premultiplied[index] = UInt8((Int(premultiplied[index]) * alpha + 127) / 255)
            premultiplied[index + 1] = UInt8((Int(premultiplied[index + 1]) * alpha + 127) / 255)
            premultiplied[index + 2] = UInt8((Int(premultiplied[index + 2]) * alpha + 127) / 255)
        }
        let data = Data(premultiplied)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    func pngData() -> Data? {
        guard let image = cgImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

import Foundation

/// Pulls blown-out white areas of a captured image toward a softer neutral
/// tone, so exported images are less harsh to look at.
///
/// The transform only touches pixels that are both bright *and* close to
/// neutral, so coloured content (a yellow highlight, a blue button) keeps its
/// hue. Shading inside the white area is preserved: the tone is scaled by the
/// pixel's own luminance, so a light-grey region stays lighter than the
/// background it sits on.
///
/// Apply this to the capture *before* compositing ink, so ink colours are
/// never altered by the tone.
public enum PaperTone {
    /// The neutral tone bright whites are pulled toward.
    public static let neutral = RGBA(r: 232, g: 229, b: 223)

    /// Luminance at which a pixel starts being toned.
    private static let luminanceFloor: Double = 200

    /// How neutral a pixel must be (its darkest channel) to be toned.
    private static let whitenessFloor: Double = 217

    /// Returns `image` with its near-white areas moved toward `neutral`.
    public static func apply(to image: ImageBuffer, tone neutral: RGBA = PaperTone.neutral) -> ImageBuffer {
        var output = image
        for y in 0..<image.height {
            for x in 0..<image.width {
                let pixel = image[x, y]
                let toned = tone(pixel, toward: neutral)
                if toned != pixel {
                    output[x, y] = toned
                }
            }
        }
        return output
    }

    /// The toned colour for a single pixel, or the pixel itself when it is
    /// not bright enough or not neutral enough to be affected.
    static func tone(_ pixel: RGBA, toward tone: RGBA) -> RGBA {
        let r = Double(pixel.r)
        let g = Double(pixel.g)
        let b = Double(pixel.b)

        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let darkest = Swift.min(r, Swift.min(g, b))

        let luminanceAmount = smoothstep(luminanceFloor, 255, luminance)
        let whitenessAmount = smoothstep(whitenessFloor, 255, darkest)
        let amount = luminanceAmount * whitenessAmount
        guard amount > 0 else { return pixel }

        // Scale the tone by the pixel's luminance so shading inside the white
        // area survives: pure white lands exactly on the tone, a slightly
        // grey pixel lands a little below it.
        let scale = luminance / 255
        let targetR = Double(tone.r) * scale
        let targetG = Double(tone.g) * scale
        let targetB = Double(tone.b) * scale

        return RGBA(
            r: UInt8((r + (targetR - r) * amount).rounded()),
            g: UInt8((g + (targetG - g) * amount).rounded()),
            b: UInt8((b + (targetB - b) * amount).rounded()),
            a: pixel.a
        )
    }

    /// A smooth 0...1 ramp between `edge0` and `edge1`.
    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
        guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
        let t = Swift.min(Swift.max((value - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

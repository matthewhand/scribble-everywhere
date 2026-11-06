import Testing
@testable import PalimpsestCore

@Suite("Ink compositor")
struct ImageCompositorTests {
    @Test func composesHorizontalLineOntoBuffer() {
        let image = ImageBuffer(width: 20, height: 10, fill: .clear)
        let stroke = Stroke(ink: .red, points: [
            StrokePoint(location: Point(x: 1, y: 5), pressure: 0.5, isTablet: false),
            StrokePoint(location: Point(x: 18, y: 5), pressure: 0.5, isTablet: false)
        ])
        let output = BufferInkCompositor().composite(strokes: [stroke], style: .standard, onto: image)

        #expect(output[5, 5] == .red)
        #expect(output[15, 5] == .red)
        #expect(output[5, 0].a == 0)
    }

    @Test func singlePointStrokeStampsADot() {
        let image = ImageBuffer(width: 10, height: 10, fill: .clear)
        let stroke = Stroke(ink: .red, points: [
            StrokePoint(location: Point(x: 5, y: 5), pressure: 0.5, isTablet: false)
        ])
        let output = BufferInkCompositor().composite(strokes: [stroke], style: .standard, onto: image)
        #expect(output[5, 5] == .red)
    }

    @Test func strokeOutsideBoundsIsIgnored() {
        let image = ImageBuffer(width: 8, height: 8, fill: .clear)
        let stroke = Stroke(ink: .red, points: [
            StrokePoint(location: Point(x: -100, y: -100), pressure: 0.5, isTablet: false)
        ])
        let output = BufferInkCompositor().composite(strokes: [stroke], style: .standard, onto: image)
        #expect(output == image)
    }

    @Test func veryLongOffscreenStrokesAreClippedToTheImage() {
        let image = ImageBuffer(width: 8, height: 8, fill: .clear)
        func point(_ x: Double, _ y: Double) -> StrokePoint {
            StrokePoint(location: Point(x: x, y: y), pressure: 0, isTablet: false)
        }
        let crossing = Stroke(ink: .red, points: [point(-100_000_000, 4), point(100_000_000, 4)])
        let outside = Stroke(ink: .blue, points: [point(-100_000_000, -100), point(100_000_000, -100)])
        let output = BufferInkCompositor().composite(strokes: [crossing, outside], style: .standard, onto: image)
        #expect(output[0, 4] == .red)
        #expect(output[7, 4] == .red)
        #expect(output[4, 0] == .clear)
    }

    @Test func nonFiniteStrokeCoordinatesAreIgnored() {
        let image = ImageBuffer(width: 8, height: 8, fill: .clear)
        let point = StrokePoint(location: Point(x: .infinity, y: 3), pressure: 0, isTablet: false)
        let output = BufferInkCompositor().composite(strokes: [Stroke(ink: .red, first: point)], style: .standard, onto: image)
        #expect(output == image)
    }

    @Test func emptyStrokeListLeavesImageUntouched() {
        let image = ImageBuffer(width: 4, height: 4, fill: .clear)
        let output = BufferInkCompositor().composite(strokes: [], style: .standard, onto: image)
        #expect(output == image)
    }

    @Test func flatteningCompositesTransparencyOntoBackground() {
        let image = ImageBuffer(width: 1, height: 1, fill: RGBA(r: 255, g: 0, b: 0, a: 128))
        let output = image.flattened(on: .blue)
        #expect(output[0, 0] == RGBA(r: 128, g: 61, b: 127, a: 255))
    }

    @Test func translucentInkUsesSourceOverAlpha() {
        let image = ImageBuffer(width: 20, height: 10, fill: RGBA(r: 0, g: 0, b: 255, a: 128))
        let stroke = Stroke(ink: RGBA(r: 255, g: 0, b: 0, a: 128), points: [
            StrokePoint(location: Point(x: 5, y: 5), pressure: 0.5, isTablet: false)
        ])
        let output = BufferInkCompositor().composite(strokes: [stroke], style: .standard, onto: image)
        #expect(output[5, 5].a == 192)
        #expect(output[5, 5].r > output[5, 5].b)
    }

    @Test func translucentStrokeOpacityDoesNotDependOnSampleDensity() {
        let image = ImageBuffer(width: 20, height: 12, fill: .clear)
        let ink = RGBA(r: 255, g: 0, b: 0, a: 128)
        func point(_ x: Double) -> StrokePoint {
            StrokePoint(location: Point(x: x, y: 6), pressure: 0, isTablet: false)
        }
        let sparse = Stroke(ink: ink, points: [point(2), point(18)])
        let dense = Stroke(ink: ink, points: (2...18).map { point(Double($0)) })
        let compositor = BufferInkCompositor()
        let sparseImage = compositor.composite(strokes: [sparse], style: .standard, onto: image)
        let denseImage = compositor.composite(strokes: [dense], style: .standard, onto: image)
        #expect(sparseImage == denseImage)
        #expect(denseImage[10, 6] == ink)
        let overlapping = compositor.composite(strokes: [dense, sparse], style: .standard, onto: image)
        #expect(overlapping[10, 6].a == 192)
    }
}

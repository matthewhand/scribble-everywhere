import Testing
@testable import PalimpsestCore

@Suite("Stroke style")
struct StrokeStyleTests {
    let style = StrokeStyle.standard

    @Test func mouseIsAlwaysFixedWidth() {
        #expect(style.width(pressure: 0.0, isTablet: false) == 4)
        #expect(style.width(pressure: 0.5, isTablet: false) == 4)
        #expect(style.width(pressure: 1.0, isTablet: false) == 4)
    }

    @Test func tabletZeroPressureFallsBackToFixedWidth() {
        #expect(style.width(pressure: 0.0, isTablet: true) == 4)
        #expect(style.width(pressure: 0.01, isTablet: true) == 4)
    }

    @Test func tabletMidPressureInterpolates() {
        #expect(style.width(pressure: 0.5, isTablet: true) == 11)
    }

    @Test func tabletFullPressureIsMax() {
        #expect(style.width(pressure: 1.0, isTablet: true) == 20)
    }

    @Test func pressureIsClampedAboveOne() {
        #expect(style.width(pressure: 5.0, isTablet: true) == 20)
    }
}

@Suite("Stroke canvas")
struct StrokeCanvasTests {
    private func point(_ x: Double, _ y: Double, tablet: Bool = true, pressure: Double = 0.5) -> StrokePoint {
        StrokePoint(location: Point(x: x, y: y), pressure: pressure, isTablet: tablet)
    }

    @Test func beginExtendEndProducesOneStroke() {
        let canvas = StrokeCanvas()
        canvas.begin(at: point(0, 0))
        canvas.extend(to: point(1, 1))
        canvas.extend(to: point(2, 2))
        canvas.end(at: point(3, 3))
        #expect(canvas.strokes.count == 1)
        #expect(canvas.strokes[0].points.count == 4)
        #expect(canvas.strokeCount == 1)
    }

    @Test func inProgressCountsAsOne() {
        let canvas = StrokeCanvas()
        canvas.begin(at: point(0, 0))
        #expect(canvas.strokeCount == 1)
        #expect(canvas.hasContent)
    }

    @Test func undoRemovesLastFinishedStroke() {
        let canvas = StrokeCanvas()
        canvas.begin(at: point(0, 0)); canvas.end(at: point(1, 1))
        canvas.begin(at: point(2, 2)); canvas.end(at: point(3, 3))
        canvas.undo()
        #expect(canvas.strokeCount == 1)
    }

    @Test func undoCancelsInProgressStroke() {
        let canvas = StrokeCanvas()
        canvas.begin(at: point(0, 0)); canvas.end(at: point(1, 1))
        canvas.begin(at: point(2, 2))
        canvas.undo()
        #expect(canvas.strokeCount == 1)
        #expect(canvas.current == nil)
    }

    @Test func clearEmptiesEverything() {
        let canvas = StrokeCanvas()
        canvas.begin(at: point(0, 0)); canvas.end(at: point(1, 1))
        canvas.clear()
        #expect(canvas.strokeCount == 0)
        #expect(!canvas.hasContent)
    }

    @Test func allStrokesIncludesCurrentLast() {
        let canvas = StrokeCanvas()
        canvas.begin(at: point(0, 0)); canvas.end(at: point(1, 1))
        canvas.begin(at: point(5, 5))
        let all = canvas.allStrokes()
        #expect(all.count == 2)
        #expect(all.last?.points.first?.location == Point(x: 5, y: 5))
    }
}

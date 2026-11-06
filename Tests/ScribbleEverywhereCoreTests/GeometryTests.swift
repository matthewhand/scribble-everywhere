import Testing
@testable import PalimpsestCore

@Suite("Geometry")
struct GeometryTests {
    @Test func rectMetrics() {
        let rect = Rect(x: 10, y: 20, width: 100, height: 50)
        #expect(rect.minX == 10)
        #expect(rect.minY == 20)
        #expect(rect.maxX == 110)
        #expect(rect.maxY == 70)
        #expect(rect.midX == 60)
        #expect(rect.midY == 45)
    }

    @Test func containsPoint() {
        let rect = Rect(x: 0, y: 0, width: 100, height: 100)
        #expect(rect.contains(Point(x: 50, y: 50)))
        #expect(rect.contains(Point(x: 0, y: 0)))
        #expect(!rect.contains(Point(x: 101, y: 50)))
    }

    @Test func intersection() {
        let a = Rect(x: 0, y: 0, width: 100, height: 100)
        let b = Rect(x: 50, y: 50, width: 100, height: 100)
        #expect(a.intersection(b) == Rect(x: 50, y: 50, width: 50, height: 50))
        #expect(a.intersection(Rect(x: 200, y: 200, width: 10, height: 10)) == nil)
    }
}

@Suite("Coordinate conversion")
struct CoordinateConversionTests {
    @Test func topLeftRectFlip() {
        let cocoa = Rect(x: 100, y: 80, width: 400, height: 200)
        let flipped = CoordinateConversion.topLeftRect(fromBottomLeft: cocoa, primaryMaxY: 1080)
        #expect(flipped == Rect(x: 100, y: 1080 - 280, width: 400, height: 200))
    }

    @Test func topLeftPointFlip() {
        let point = CoordinateConversion.topLeftPoint(fromBottomLeft: Point(x: 42, y: 7), primaryMaxY: 1080)
        #expect(point == Point(x: 42, y: 1073))
    }

    @Test func roundTrip() {
        let cocoa = Point(x: 300, y: 200)
        let flipped = CoordinateConversion.topLeftPoint(fromBottomLeft: cocoa, primaryMaxY: 1080)
        let back = CoordinateConversion.topLeftPoint(fromBottomLeft: flipped, primaryMaxY: 1080)
        #expect(back == cocoa)
    }
}

@Suite("Display lookup")
struct DisplayLookupTests {
    @Test func findsDisplayContainingPoint() {
        let displays = [
            DisplayFrame(id: 1, frame: Rect(x: 0, y: 0, width: 1920, height: 1080), scale: 2),
            DisplayFrame(id: 2, frame: Rect(x: 1920, y: 0, width: 1280, height: 800), scale: 1)
        ]
        #expect(DisplayLookup.display(containing: Point(x: 500, y: 500), in: displays)?.id == 1)
        #expect(DisplayLookup.display(containing: Point(x: 2000, y: 100), in: displays)?.id == 2)
        #expect(DisplayLookup.display(containing: Point(x: 5000, y: 5000), in: displays) == nil)
    }

    private let sideBySide = [
        DisplayFrame(id: 1, frame: Rect(x: 0, y: 0, width: 1920, height: 1080), scale: 2),
        DisplayFrame(id: 2, frame: Rect(x: 1920, y: 0, width: 1280, height: 800), scale: 1)
    ]

    @Test func coveringPicksDisplayWithTheWindowCentre() {
        let window = Rect(x: 1800, y: 100, width: 400, height: 300)
        #expect(DisplayLookup.display(covering: window, in: sideBySide)?.id == 2)
    }

    @Test func coveringFallsBackToLargestOverlapWhenCentreIsOffDisplay() {
        // A window hanging mostly over display 1 whose centre lands off every
        // display (above the screens): the centre lookup fails, so the largest
        // overlap decides. Display 1 gets the bigger share.
        let window = Rect(x: -100, y: -400, width: 2400, height: 600)
        #expect(DisplayLookup.display(covering: window, in: sideBySide)?.id == 1)
    }

    @Test func coveringFallsBackToFirstDisplayWhenNothingOverlaps() {
        let window = Rect(x: 9000, y: 9000, width: 100, height: 100)
        #expect(DisplayLookup.display(covering: window, in: sideBySide)?.id == 1)
        #expect(DisplayLookup.display(covering: window, in: []) == nil)
    }
}

@Suite("Capture geometry")
struct CaptureGeometryTests {
    @Test func plansDisplayLocalRectAndPixels() {
        let display = Rect(x: 0, y: 0, width: 1920, height: 1080)
        let window = Rect(x: 100, y: 50, width: 800, height: 600)
        let plan = CaptureGeometry.plan(window: window, display: display, scale: 2)
        #expect(plan?.sourceRect == Rect(x: 100, y: 50, width: 800, height: 600))
        #expect(plan?.pixelWidth == 1600)
        #expect(plan?.pixelHeight == 1200)
    }

    @Test func clampsToDisplayBounds() {
        let display = Rect(x: 0, y: 0, width: 1920, height: 1080)
        let window = Rect(x: 1900, y: 1000, width: 200, height: 200)
        let plan = CaptureGeometry.plan(window: window, display: display, scale: 1)
        #expect(plan?.sourceRect == Rect(x: 1900, y: 1000, width: 20, height: 80))
        #expect(plan?.pixelWidth == 20)
        #expect(plan?.pixelHeight == 80)
    }

    @Test func offsetsForSecondaryDisplayOrigin() {
        let display = Rect(x: 1920, y: 0, width: 1280, height: 800)
        let window = Rect(x: 2000, y: 100, width: 400, height: 300)
        let plan = CaptureGeometry.plan(window: window, display: display, scale: 1)
        #expect(plan?.sourceRect == Rect(x: 80, y: 100, width: 400, height: 300))
    }

    @Test func clampsWindowOverhangingTheLeftEdge() {
        let display = Rect(x: 0, y: 0, width: 1920, height: 1080)
        let window = Rect(x: -50, y: 20, width: 100, height: 100)
        let plan = CaptureGeometry.plan(window: window, display: display, scale: 1)
        #expect(plan?.sourceRect == Rect(x: 0, y: 20, width: 50, height: 100))
    }

    @Test func rejectsDegenerateRegion() {
        let display = Rect(x: 0, y: 0, width: 100, height: 100)
        #expect(CaptureGeometry.plan(window: Rect(x: 500, y: 500, width: 10, height: 10), display: display, scale: 1) == nil)
        #expect(CaptureGeometry.plan(window: Rect(x: 0, y: 0, width: 0, height: 10), display: display, scale: 1) == nil)
        #expect(CaptureGeometry.plan(window: Rect(x: 0, y: 0, width: 10, height: 10), display: display, scale: 0) == nil)
    }

    @Test func fractionalScaleRoundsPixels() {
        let display = Rect(x: 0, y: 0, width: 1000, height: 1000)
        let window = Rect(x: 0, y: 0, width: 101, height: 99)
        let plan = CaptureGeometry.plan(window: window, display: display, scale: 1.5)
        #expect(plan?.pixelWidth == 152)
        #expect(plan?.pixelHeight == 149)
    }
}

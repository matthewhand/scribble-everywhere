import Testing
import WinSDK
import PalimpsestCore
@testable import PalimpsestWin

/// These exercise the production contact transitions, not a physical digitizer.
@Suite("Windows pointer contacts", .serialized)
@MainActor
struct PointerContactTests {
    @Test func pressureUsesTheWindowsRangeAndClampsOutliers() {
        #expect(WinOverlay.normalizedPressure(0) == 0)
        #expect(WinOverlay.normalizedPressure(512) == 0.5)
        #expect(WinOverlay.normalizedPressure(1024) == 1)
        #expect(WinOverlay.normalizedPressure(4096) == 1)
        #expect(WinOverlay.normalizedPressure(UInt32.max) == 1)
    }

    private func sample(_ x: Double, pressure: Double = 0.6, pen: Bool = true) -> StrokePoint {
        StrokePoint(location: Point(x: x, y: 10), pressure: pressure, isTablet: pen)
    }

    @Test func secondContactCannotChangeOrEndTheFirstAndLiftRetainsPressure() throws {
        let canvas = StrokeCanvas()
        let overlay = WinOverlay()
        overlay.attach(canvas: canvas)
        overlay.isClickThrough = false
        var completed = 0
        overlay.onStrokeChanged = { completed += 1 }
        overlay.handlePointerContact(message: UINT(WM_POINTERDOWN), pointerId: 1, sample: sample(0), flags: UInt32(POINTER_FLAG_INCONTACT))
        overlay.handlePointerContact(message: UINT(WM_POINTERDOWN), pointerId: 2, sample: sample(100, pen: false), flags: UInt32(POINTER_FLAG_INCONTACT))
        overlay.handlePointerContact(message: UINT(WM_POINTERUPDATE), pointerId: 2, sample: sample(200, pen: false), flags: UInt32(POINTER_FLAG_INCONTACT))
        overlay.handlePointerContact(message: UINT(WM_POINTERUP), pointerId: 2, sample: sample(300, pen: false), flags: 0)
        #expect(canvas.current?.points.count == 1)
        #expect(canvas.strokes.isEmpty)
        overlay.handlePointerContact(message: UINT(WM_POINTERUPDATE), pointerId: 1, sample: sample(10, pressure: 0.8), flags: UInt32(POINTER_FLAG_INCONTACT))
        overlay.handlePointerContact(message: UINT(WM_POINTERUP), pointerId: 1, sample: sample(12, pressure: 0), flags: 0)
        let stroke = try #require(canvas.strokes.first)
        #expect(stroke.points.map(\.location.x) == [0, 10, 12])
        #expect(stroke.points.last?.pressure == 0.8)
        #expect(stroke.points.allSatisfy { $0.isTablet })
        #expect(completed == 1)
    }

    @Test func canceledTouchDiscardsOnlyItsInkAndAllowsTheNextContact() {
        let canvas = StrokeCanvas()
        canvas.begin(at: sample(50))
        canvas.end(at: sample(60))
        let finished = canvas.strokes
        let overlay = WinOverlay()
        overlay.attach(canvas: canvas)
        overlay.isClickThrough = false
        overlay.handlePointerContact(message: UINT(WM_POINTERDOWN), pointerId: 10, sample: sample(0, pen: false), flags: UInt32(POINTER_FLAG_INCONTACT))
        overlay.handlePointerContact(message: UINT(WM_POINTERUPDATE), pointerId: 10, sample: sample(10, pen: false), flags: UInt32(POINTER_FLAG_CANCELED))
        #expect(canvas.current == nil)
        #expect(canvas.strokes == finished)
        overlay.handlePointerContact(message: UINT(WM_POINTERDOWN), pointerId: 11, sample: sample(20, pen: false), flags: UInt32(POINTER_FLAG_INCONTACT))
        overlay.handlePointerContact(message: UINT(WM_POINTERUP), pointerId: 11, sample: sample(30, pen: false), flags: 0)
        #expect(canvas.strokes.count == 2)
        #expect(canvas.strokes.last?.points.allSatisfy { !$0.isTablet } == true)
    }

    @Test func idleAndHoverCannotAddInkOrChangeContactPressure() {
        let canvas = StrokeCanvas()
        let overlay = WinOverlay()
        overlay.attach(canvas: canvas)
        overlay.handlePointerContact(message: UINT(WM_POINTERDOWN), pointerId: 1, sample: sample(0), flags: UInt32(POINTER_FLAG_INCONTACT))
        #expect(!canvas.hasContent)
        overlay.isClickThrough = false
        overlay.handlePointerContact(message: UINT(WM_POINTERDOWN), pointerId: 1, sample: sample(1), flags: UInt32(POINTER_FLAG_INCONTACT))
        overlay.handlePointerContact(message: UINT(WM_POINTERUPDATE), pointerId: 1, sample: sample(100, pressure: 0), flags: 0)
        overlay.handlePointerContact(message: UINT(WM_POINTERUP), pointerId: 1, sample: sample(2, pressure: 0), flags: 0)
        #expect(canvas.strokes.first?.points.map(\.location.x) == [1, 2])
        #expect(canvas.strokes.first?.points.last?.pressure == 0.6)
    }
}

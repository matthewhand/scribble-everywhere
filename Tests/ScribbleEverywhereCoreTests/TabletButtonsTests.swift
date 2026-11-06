import Testing
@testable import PalimpsestCore

@Suite("Tablet buttons")
struct TabletButtonsTests {
    @Test func decodeNone() {
        #expect(TabletButtons.decode(bits: 0) == .none)
    }

    @Test func decodeEachBit() {
        #expect(TabletButtons.decode(bits: 0b001) == TabletButtons(tip: true, barrel1: false, barrel2: false))
        #expect(TabletButtons.decode(bits: 0b010) == TabletButtons(tip: false, barrel1: true, barrel2: false))
        #expect(TabletButtons.decode(bits: 0b100) == TabletButtons(tip: false, barrel1: false, barrel2: true))
    }

    @Test func decodeAllBits() {
        #expect(TabletButtons.decode(bits: 0b111) == TabletButtons(tip: true, barrel1: true, barrel2: true))
    }

    @Test func ignoresHighBits() {
        #expect(TabletButtons.decode(bits: 1 << 20) == .none)
    }
}

@Suite("Button edge detector")
struct ButtonEdgeDetectorTests {
    @Test func pressFiresOnceOnRisingEdge() {
        var detector = ButtonEdgeDetector()
        #expect(detector.update(TabletButtons(tip: false, barrel1: true, barrel2: false)).barrel1Pressed)
        #expect(!detector.update(TabletButtons(tip: false, barrel1: true, barrel2: false)).barrel1Pressed)
        #expect(!detector.update(TabletButtons(tip: false, barrel1: false, barrel2: false)).barrel1Pressed)
        #expect(detector.update(TabletButtons(tip: false, barrel1: true, barrel2: false)).barrel1Pressed)
    }

    @Test func detectsBarrel2Independently() {
        var detector = ButtonEdgeDetector()
        let result = detector.update(TabletButtons(tip: true, barrel1: false, barrel2: true))
        #expect(!result.barrel1Pressed)
        #expect(result.barrel2Pressed)
    }

    @Test func tipDoesNotTriggerBarrelActions() {
        var detector = ButtonEdgeDetector()
        let result = detector.update(TabletButtons(tip: true, barrel1: false, barrel2: false))
        #expect(!result.barrel1Pressed)
        #expect(!result.barrel2Pressed)
    }

    @Test func resetMakesTheHeldButtonFireAgain() {
        var detector = ButtonEdgeDetector()
        let held = TabletButtons(tip: false, barrel1: true, barrel2: false)
        #expect(detector.update(held).barrel1Pressed)
        #expect(!detector.update(held).barrel1Pressed)
        detector.reset()
        #expect(detector.update(held).barrel1Pressed)
    }
}

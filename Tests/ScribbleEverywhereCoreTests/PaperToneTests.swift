import Testing
@testable import PalimpsestCore

@Suite("Paper tone")
struct PaperToneTests {
    @Test func pureWhiteBecomesTheNeutralTone() {
        let output = PaperTone.tone(RGBA(r: 255, g: 255, b: 255), toward: PaperTone.neutral)
        #expect(output == PaperTone.neutral)
    }

    @Test func darkPixelsAreUntouched() {
        let dark = RGBA(r: 20, g: 20, b: 24)
        #expect(PaperTone.tone(dark, toward: PaperTone.neutral) == dark)
    }

    @Test func colouredPixelsKeepTheirHue() {
        let yellow = RGBA(r: 255, g: 240, b: 120)
        #expect(PaperTone.tone(yellow, toward: PaperTone.neutral) == yellow)
    }

    @Test func alphaIsPreserved() {
        let output = PaperTone.tone(RGBA(r: 255, g: 255, b: 255, a: 128), toward: PaperTone.neutral)
        #expect(output.a == 128)
    }

    @Test func shadingInsideTheWhiteAreaSurvives() {
        let background = PaperTone.tone(RGBA(r: 255, g: 255, b: 255), toward: PaperTone.neutral)
        let shade = PaperTone.tone(RGBA(r: 240, g: 240, b: 240), toward: PaperTone.neutral)
        #expect(shade.r < background.r)
    }

    @Test func applyLeavesDarkImagesUnchanged() {
        var image = ImageBuffer(width: 2, height: 2, fill: RGBA(r: 18, g: 18, b: 20))
        image[0, 0] = RGBA(r: 200, g: 60, b: 60)
        let output = PaperTone.apply(to: image)
        #expect(output == image)
    }

    @Test func applyTonesTheWhiteBackground() {
        var image = ImageBuffer(width: 2, height: 2, fill: RGBA(r: 255, g: 255, b: 255))
        image[0, 0] = RGBA(r: 10, g: 10, b: 10)
        let output = PaperTone.apply(to: image)
        #expect(output[1, 0] == PaperTone.neutral)
        #expect(output[0, 0] == RGBA(r: 10, g: 10, b: 10))
    }
}

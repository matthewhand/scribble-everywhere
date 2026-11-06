import Testing
@testable import PalimpsestCore

@Suite("Palette")
struct PaletteTests {
    @Test func standardHasThreeDefaultsAndSelectsTheFirst() {
        let palette = Palette.standard
        #expect(palette.colors == [.red, .blue, .green])
        #expect(palette.current == .red)
    }

    @Test func cycleWrapsAround() {
        var palette = Palette.standard
        palette.cycle()
        #expect(palette.current == .blue)
        palette.cycle()
        #expect(palette.current == .green)
        palette.cycle()
        #expect(palette.current == .red)
    }

    @Test func selectIgnoresOutOfRange() {
        var palette = Palette.standard
        palette.select(7)
        #expect(palette.current == .red)
        palette.select(2)
        #expect(palette.current == .green)
    }

    @Test func addAppendsAndSelectsWithoutDuplicating() {
        var palette = Palette.standard
        let purple = RGBA(r: 175, g: 82, b: 222)
        palette.add(purple)
        #expect(palette.colors.count == 4)
        #expect(palette.current == purple)
        palette.add(RGBA(r: 175, g: 82, b: 222), select: false)
        #expect(palette.colors.count == 4)
    }

    @Test func removeKeepsSelectionOnTheSameColour() {
        var palette = Palette(colors: [.red, .blue, .green], index: 2)
        palette.remove(at: 0)
        #expect(palette.colors == [.blue, .green])
        #expect(palette.current == .green)
    }

    @Test func removeClampsWhenTheSelectedColourGoes() {
        var palette = Palette(colors: [.red, .blue, .green], index: 2)
        palette.remove(at: 2)
        #expect(palette.colors == [.red, .blue])
        #expect(palette.current == .blue)
    }

    @Test func cannotRemoveTheLastColour() {
        var palette = Palette(colors: [.red])
        palette.remove(at: 0)
        #expect(palette.colors == [.red])
    }

    @Test func customIndicesHandlePalettesSmallerThanTheDefaults() {
        var palette = Palette.standard
        palette.remove(at: 2)
        #expect(palette.customIndices.isEmpty)
        palette.remove(at: 1)
        #expect(palette.customIndices.isEmpty)
        palette.add(.blue)
        palette.add(.green)
        palette.add(RGBA(r: 175, g: 82, b: 222))
        #expect(palette.customIndices == [3])
    }

    @Test func customIndicesFollowColoursAfterDefaultsAreEditedOrRemoved() {
        let purple = RGBA(r: 175, g: 82, b: 222)
        let orange = RGBA(r: 255, g: 149, b: 0)
        var palette = Palette.standard
        palette.add(purple)
        palette.remove(at: 0)
        #expect(palette.customIndices == [2])
        palette.replace(at: 0, with: orange)
        #expect(palette.customIndices == [0, 2])
        palette.add(.red)
        #expect(palette.customIndices == [0, 2])
    }

    @Test func replaceEditsInPlaceAndKeepsSelection() {
        var palette = Palette.standard
        let orange = RGBA(r: 255, g: 149, b: 0)
        palette.replace(at: palette.index, with: orange)
        #expect(palette.colors.count == 3)
        #expect(palette.colors[0] == orange)
        #expect(palette.current == orange)
    }

    @Test func repeatedReplaceCallsSimulatePickerDragWithoutGrowth() {
        var palette = Palette.standard
        for step in 0...255 {
            palette.replace(at: palette.index, with: RGBA(r: UInt8(step), g: 40, b: 90))
        }
        #expect(palette.colors.count == 3)
    }

    @Test func replaceWithExistingColourSelectsItWithoutDuplicating() {
        var palette = Palette.standard
        palette.select(0)
        palette.replace(at: 0, with: .blue)
        #expect(palette.colors.count == 3)
        #expect(palette.index == 1)
        #expect(palette.current == .blue)
    }

    @Test func replaceIgnoresOutOfRangePosition() {
        var palette = Palette.standard
        palette.replace(at: 9, with: .blue)
        #expect(palette.colors == Palette.defaultColors)
    }

    @Test func emptyInputFallsBackToDefaults() {
        var palette = Palette(colors: [])
        #expect(palette.colors == Palette.defaultColors)
        palette.cycle()
        #expect(palette.current == .blue)
    }

    @Test func hexRoundTrips() {
        let purple = RGBA(r: 175, g: 82, b: 222)
        #expect(purple.hex == "#AF52DEFF")
        #expect(RGBA(hex: "#AF52DE") == purple)
        #expect(RGBA(hex: "AF52DEFF") == purple)
        #expect(RGBA(hex: "#ZZ") == nil)
    }
}

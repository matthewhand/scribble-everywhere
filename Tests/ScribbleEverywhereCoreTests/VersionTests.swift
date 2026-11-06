import Testing
@testable import PalimpsestCore

@Suite("Version")
struct VersionTests {
    @Test func shortVersionHasThreeNumericComponents() {
        let parts = PalimpsestVersion.short.split(separator: ".")
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { Int($0) != nil })
    }

    @Test func displayStringContainsTheShortVersion() {
        #expect(PalimpsestVersion.displayString.contains("ScribbleEverywhere"))
        #expect(PalimpsestVersion.displayString.contains(PalimpsestVersion.short))
    }
}

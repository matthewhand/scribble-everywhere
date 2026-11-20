import Testing
@testable import ScribbleEverywhereCore

@Suite("Version")
struct VersionTests {
    @Test func shortVersionHasThreeNumericComponents() {
        let parts = ScribbleEverywhereVersion.short.split(separator: ".")
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { Int($0) != nil })
    }

    @Test func displayStringContainsTheShortVersion() {
        #expect(ScribbleEverywhereVersion.displayString.contains("ScribbleEverywhere"))
        #expect(ScribbleEverywhereVersion.displayString.contains(ScribbleEverywhereVersion.short))
    }
}

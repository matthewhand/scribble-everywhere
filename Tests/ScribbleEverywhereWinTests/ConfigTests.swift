import Foundation
import Testing
import PalimpsestCore
@testable import PalimpsestWin

@Suite("Windows configuration migration")
struct ConfigTests {
    @Test func legacyPinnedHandleRequiresReselectionWithoutLosingOtherSettings() throws {
        let old = Data(##"{"pasteOverrideHwnd":"1234","pasteOverrideTitle":"Document","hotkeyCode":90}"##.utf8)
        let config = try JSONDecoder().decode(WinConfig.self, from: old)
        #expect(config.hotkeyCode == 90)
        #expect(config.pasteOverrideHwnd == "1234")
        #expect(config.pasteOverrideTitle == "Document")
        #expect(config.pasteOverrideIdentity == nil)
        #expect(WinWindowTargeting.pinnedWindow(bits: config.pasteOverrideHwnd, expected: config.pasteOverrideIdentity) == nil)
    }

    @Test func pinnedIdentityRejectsRecycledProcessesAndChangedWindows() throws {
        let expected = WinWindowTargeting.Identity(processId: 42, processCreation: 100, className: "Editor", title: "Document")
        var other = expected
        #expect(WinWindowTargeting.identityMatches(expected: expected, observed: other))
        other.processId = 43
        #expect(!WinWindowTargeting.identityMatches(expected: expected, observed: other))
        other = expected; other.processCreation = 101
        #expect(!WinWindowTargeting.identityMatches(expected: expected, observed: other))
        other = expected; other.className = "Browser"
        #expect(!WinWindowTargeting.identityMatches(expected: expected, observed: other))
        other = expected; other.title = "Other document"
        #expect(!WinWindowTargeting.identityMatches(expected: expected, observed: other))
        #expect(!WinWindowTargeting.identityMatches(expected: expected, observed: nil))
        #expect(!WinWindowTargeting.identityMatches(expected: nil, observed: expected))
        var config = WinConfig()
        config.pasteOverrideHwnd = "1234"
        config.pasteOverrideIdentity = expected
        let decoded = try JSONDecoder().decode(WinConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.pasteOverrideIdentity == expected)
    }

    @Test func focusedHotkeyMatchesTheCustomBindingAndIgnoresRegistrationFlags() {
        var config = WinConfig()
        config.hotkeyCode = 0x4B // K
        config.hotkeyModifiers = 6 | 0x4000 // Ctrl+Shift, MOD_NOREPEAT
        #expect(config.matchesHotkey(key: 0x4B, modifiers: 6))
        #expect(!config.matchesHotkey(key: 0x44, modifiers: 3))
        #expect(!config.matchesHotkey(key: 0x4B, modifiers: 2))
        #expect(!config.matchesHotkey(key: 0x4B, modifiers: 7))
        #expect(config.hotkeyDisplay == "Ctrl+Shift+K")
        config.hotkeyModifiers = 10 // Ctrl+Win
        #expect(config.hotkeyDisplay == "Ctrl+Win+K")
    }

    @Test func olderConfigPreservesPaletteAndHotkeyWhenNewKeysAreMissing() throws {
        let old = Data(##"{"hotkeyCode":90,"hotkeyModifiers":6,"paletteColors":["#123456FF","#FFFFFFFF"],"paletteIndex":1,"pasteTarget":"frontmostApp"}"##.utf8)
        let config = try JSONDecoder().decode(WinConfig.self, from: old)
        #expect(config.hotkeyCode == 90)
        #expect(config.hotkeyModifiers == 6)
        #expect(config.paletteColors == ["#123456FF", "#FFFFFFFF"])
        #expect(config.paletteIndex == 1)
        #expect(config.pasteTarget == "frontmostApp")
        #expect(config.paperTone)
        #expect(config.saveAnnotations)
        #expect(config.colourNames.isEmpty)
        #expect(config.stopAction == nil)
    }

    @Test func emptyObjectUsesDefaults() throws {
        let config = try JSONDecoder().decode(WinConfig.self, from: Data("{}".utf8))
        let defaults = WinConfig()
        #expect(config.hotkeyCode == defaults.hotkeyCode)
        #expect(config.hotkeyModifiers == defaults.hotkeyModifiers)
        #expect(config.palette == defaults.palette)
        #expect(config.floatingPosition == .topRight)
        #expect(!config.launchOnStartup)
    }

    @Test func currentSettingsRoundTripWithoutLosingFalseValuesOrNames() throws {
        var original = WinConfig()
        original.paperTone = false
        original.saveAnnotations = false
        original.stopAction = "clipboard"
        original.pasteChord = "altV"
        original.annotationFolder = "C:\\Ink"
        original.colourNames = ["#123456FF": "My ink"]
        original.launchOnStartup = true
        let decoded = try JSONDecoder().decode(WinConfig.self, from: JSONEncoder().encode(original))
        #expect(!decoded.paperTone)
        #expect(!decoded.saveAnnotations)
        #expect(decoded.stopAction == "clipboard")
        #expect(decoded.pasteChord == "altV")
        #expect(decoded.annotationFolder == original.annotationFolder)
        #expect(decoded.colourNames == original.colourNames)
        #expect(decoded.launchOnStartup)
    }
}

import Testing
@testable import PalimpsestCore

@Suite("Hotkey")
struct HotkeyTests {
    @Test func standardDisplayString() {
        #expect(Hotkey.standard.displayString == "⌥⌘D")
    }

    @Test func displayStringOrderAndGlyphs() {
        let hotkey = Hotkey(keyCode: 2, modifiers: [.control, .option, .shift, .command])
        #expect(hotkey.displayString == "⌃⌥⇧⌘D")
    }

    @Test func unknownKeyCodeFallsBack() {
        #expect(Hotkey(keyCode: 999, modifiers: [.command]).displayString == "⌘Key 999")
    }

    @Test func carbonModifierMapping() {
        #expect(KeyModifiers.command.rawValue == 1)
        let hotkey = Hotkey(keyCode: 2, modifiers: [.command, .option])
        #expect(hotkey.carbonModifiers == (256 | 2048))
    }

    @Test func validityRequiresModifier() {
        #expect(Hotkey.standard.isValid)
        #expect(!Hotkey(keyCode: 2, modifiers: []).isValid)
    }

    @Test func modifierKeyCodeDetection() {
        #expect(KeyCodeNames.isModifier(55))
        #expect(!KeyCodeNames.isModifier(2))
    }
}

@Suite("Paste target")
struct PasteTargetTests {
    @Test func previousAppPreference() {
        #expect(PasteTarget.choose(preference: .previousApp, previousApp: "A", frontmostApp: "B") == "A")
    }

    @Test func previousAppFallsBackToFrontmost() {
        #expect(PasteTarget.choose(preference: .previousApp, previousApp: nil, frontmostApp: "B") == "B")
    }

    @Test func frontmostAppPreference() {
        #expect(PasteTarget.choose(preference: .frontmostApp, previousApp: "A", frontmostApp: "B") == "B")
    }

    @Test func noCandidates() {
        #expect(PasteTarget.choose(preference: .previousApp, previousApp: nil, frontmostApp: nil) == nil)
    }

    @Test func overrideWinsOverPreference() {
        #expect(PasteTarget.choose(preference: .previousApp, previousApp: "A", frontmostApp: "B", overrideApp: "P") == "P")
        #expect(PasteTarget.choose(preference: .frontmostApp, previousApp: nil, frontmostApp: "B", overrideApp: "P") == "P")
    }

    @Test func emptyOverrideIsIgnored() {
        #expect(PasteTarget.choose(preference: .previousApp, previousApp: "A", frontmostApp: "B", overrideApp: "") == "A")
        #expect(PasteTarget.choose(preference: .previousApp, previousApp: nil, frontmostApp: "B", overrideApp: nil) == "B")
    }

    @Test func ownAppIndirectCandidatesAreDropped() {
        // The previous app is ourselves: fall back to the frontmost window.
        #expect(PasteTarget.choose(preference: .previousApp, previousApp: "ME", frontmostApp: "B", excluding: "ME") == "B")
        // The frontmost app is ourselves: fall back to the previous app.
        #expect(PasteTarget.choose(preference: .frontmostApp, previousApp: "A", frontmostApp: "ME", excluding: "ME") == "A")
    }

    @Test func ownAppOverrideIsDroppedRatherThanUsed() {
        // A pinned override pointing at ourselves must not win; the normal
        // preference logic runs against the surviving candidates.
        #expect(PasteTarget.choose(preference: .previousApp, previousApp: "A", frontmostApp: "B", overrideApp: "ME", excluding: "ME") == "A")
    }

    @Test func ownAppExclusionCanLeaveNoTarget() {
        #expect(PasteTarget.choose(preference: .previousApp, previousApp: "ME", frontmostApp: "ME", excluding: "ME") == nil)
    }

    @Test func excludingOtherAppsIsUnaffected() {
        #expect(PasteTarget.choose(preference: .previousApp, previousApp: "A", frontmostApp: "B", excluding: "OTHER") == "A")
    }
}

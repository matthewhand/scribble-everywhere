import AppKit
import ServiceManagement
import Testing
import PalimpsestCore
@testable import PalimpsestInk

@Suite("Mac runtime boundaries")
@MainActor
struct MacRuntimeTests {
    @Test func permissionAndActivationFailureNeverSendPaste() async {
        var activated = 0, sent = 0
        let denied = Paster(log: { _ in }, isTrusted: { false }, activate: { _ in
            activated += 1; return true
        }, sendPaste: { sent += 1; return true })
        #expect(await denied.paste(into: "test.app") == false)
        let unfocused = Paster(log: { _ in }, isTrusted: { true }, activate: { _ in
            activated += 1; return false
        }, sendPaste: { sent += 1; return true })
        #expect(await unfocused.paste(into: "test.app") == false)
        #expect(await unfocused.paste(into: nil) == false)
        #expect(activated == 1)
        #expect(sent == 0)
    }

    @Test func pasteReportsEventCreationFailureAndSendsOnce() async {
        var sent = 0
        let paster = Paster(log: { _ in }, isTrusted: { true }, activate: { _ in true },
            sendPaste: { sent += 1; return false })
        #expect(await paster.paste(into: "test.app") == false)
        #expect(sent == 1)
    }

    @Test func pasteForwardsExpectedProcessAndDoesNotSendOnActivationFailure() async {
        var receivedProcess: pid_t?
        var sent = 0
        let paster = Paster(log: { _ in }, isTrusted: { true }, activateProcess: { _, processID in
            receivedProcess = processID
            return false
        }, sendPaste: { sent += 1; return true })
        let pasted = await paster.paste(into: "editor", expectedProcessID: 42)
        #expect(!pasted)
        #expect(receivedProcess == 42)
        #expect(sent == 0)
    }

    @Test func cancelledDeliveryNeverSendsKeys() async {
        var sent = 0
        let paster = Paster(log: { _ in }, isTrusted: { true }, activate: { _ in true },
            sendPaste: { sent += 1; return true })
        let task = Task { await paster.paste(into: "test.app") }
        task.cancel()
        #expect(await task.value == false)
        #expect(sent == 0)
    }

    @Test func privatePasteboardContainsTheWrittenImageData() {
        let pasteboard = NSPasteboard(name: .init("PalimpsestTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10])
        let image = ImageBuffer(width: 1, height: 1, pixels: [255, 0, 0, 255])
        #expect(ClipboardImageWriter(pasteboard: pasteboard).writeNow(image: image, png: png))
        #expect(pasteboard.data(forType: .png) == png)
    }

    @Test func paletteTracksSelectedEdgeAndDisplayAsWidthChanges() {
        let secondary = NSRect(x: -1920, y: -1000, width: 1920, height: 1080)
        #expect(FloatingPaletteController.width(colourCount: 3) == 190)
        let left = FloatingPaletteController.frame(position: .topLeft, width: 190, visibleFrame: secondary)
        let right = FloatingPaletteController.frame(position: .topRight, width: 190, visibleFrame: secondary)
        let wider = FloatingPaletteController.frame(position: .topRight, width: 224, visibleFrame: secondary)
        #expect(left.minX == -1904 && left.maxY == 64)
        #expect(right.maxX == -16 && wider.maxX == -16)
    }

    @Test func palettePenContactFiresOnlyOnceUntilReleaseOrExit() {
        var edge = FloatingPaletteTabletEdge()
        let hover = edge.press(tip: false)
        let firstPress = edge.press(tip: true)
        let held = edge.press(tip: true)
        let lift = edge.press(tip: false)
        let secondPress = edge.press(tip: true)
        edge.reset()
        let pressAfterReset = edge.press(tip: true)
        #expect(!hover)
        #expect(firstPress)
        #expect(!held)
        #expect(!lift)
        #expect(secondPress)
        #expect(pressAfterReset)
    }

    @Test func windowAcrossDisplayGapUsesIntersectingDisplay() throws {
        let displays = [
            DisplayFrame(id: 1, frame: Rect(x: 0, y: 0, width: 100, height: 100), scale: 1),
            DisplayFrame(id: 2, frame: Rect(x: 200, y: 0, width: 100, height: 100), scale: 2)
        ]
        let window = Rect(x: 70, y: 10, width: 140, height: 80)
        let display = try #require(ScreenCapturer.captureDisplay(for: window, in: displays))
        #expect(display.id == 1)
        #expect(CaptureGeometry.plan(window: window, display: display.frame, scale: display.scale) != nil)
    }

    @Test func ownFrontmostAppFallsBackToExternalCaptureTarget() {
        #expect(WindowTargeting.previousApplication(frontmost: "palimpsest", own: "palimpsest", target: "editor") == "editor")
        #expect(WindowTargeting.previousApplication(frontmost: nil, own: "palimpsest", target: "editor") == "editor")
        #expect(WindowTargeting.previousApplication(frontmost: "browser", own: "palimpsest", target: "editor") == "browser")
    }

    @Test func missingOrInvalidPasteDestinationNeverFallsBackToAnotherApp() {
        #expect(WindowTargeting.deliveryApplication(preference: .previousApp, previous: nil, frontmost: "other", pinned: nil, own: "self") == nil)
        #expect(WindowTargeting.deliveryApplication(preference: .frontmostApp, previous: "other", frontmost: nil, pinned: nil, own: "self") == nil)
        #expect(WindowTargeting.deliveryApplication(preference: .previousApp, previous: "other", frontmost: "other", pinned: "self", own: "self") == nil)
        #expect(WindowTargeting.deliveryApplication(preference: .frontmostApp, previous: "previous", frontmost: "front", pinned: "pinned", own: "self") == "pinned")
    }

    @Test func changedClosedOrCancelledWindowCannotCompleteSessionCapture() {
        let identity = WindowIdentity(windowID: 10, processID: 20)
        let frame = Rect(x: 10, y: 20, width: 100, height: 80)
        let original = WindowTarget(identity: identity, frame: frame, applicationName: nil, bundleIdentifier: "editor")
        let otherWindow = WindowTarget(identity: WindowIdentity(windowID: 11, processID: 20), frame: frame, applicationName: nil, bundleIdentifier: "editor")
        let reusedWindowID = WindowTarget(identity: WindowIdentity(windowID: 10, processID: 21), frame: frame, applicationName: nil, bundleIdentifier: "editor")
        #expect(WindowTargeting.canCompleteCapture(requiresSession: true, isCapturing: true, current: original, snapshot: original, session: identity))
        #expect(!WindowTargeting.canCompleteCapture(requiresSession: true, isCapturing: true, current: otherWindow, snapshot: original, session: identity))
        #expect(!WindowTargeting.canCompleteCapture(requiresSession: true, isCapturing: true, current: reusedWindowID, snapshot: original, session: identity))
        #expect(!WindowTargeting.canCompleteCapture(requiresSession: true, isCapturing: true, current: nil, snapshot: original, session: identity))
        #expect(!WindowTargeting.canCompleteCapture(requiresSession: true, isCapturing: false, current: original, snapshot: original, session: identity))
    }

    @Test func captureSnapshotCheckRejectsDifferentMovedOrResizedWindowWithoutSession() {
        let identity = WindowIdentity(windowID: 10, processID: 20)
        let original = WindowTarget(identity: identity, frame: Rect(x: 10, y: 20, width: 100, height: 80), applicationName: nil, bundleIdentifier: "editor")
        let different = WindowTarget(identity: WindowIdentity(windowID: 11, processID: 20), frame: original.frame, applicationName: nil, bundleIdentifier: "editor")
        let moved = WindowTarget(identity: identity, frame: Rect(x: 11, y: 20, width: 100, height: 80), applicationName: nil, bundleIdentifier: "editor")
        let resized = WindowTarget(identity: identity, frame: Rect(x: 10, y: 20, width: 101, height: 80), applicationName: nil, bundleIdentifier: "editor")
        #expect(WindowTargeting.canCompleteCapture(requiresSession: false, isCapturing: false, current: original, snapshot: original, session: nil))
        #expect(!WindowTargeting.canCompleteCapture(requiresSession: false, isCapturing: false, current: different, snapshot: original, session: nil))
        #expect(!WindowTargeting.canCompleteCapture(requiresSession: false, isCapturing: false, current: moved, snapshot: original, session: nil))
        #expect(!WindowTargeting.canCompleteCapture(requiresSession: false, isCapturing: false, current: resized, snapshot: original, session: nil))
        #expect(WindowTargeting.matchesCaptureSnapshot(original, snapshot: original))
        #expect(!WindowTargeting.matchesCaptureSnapshot(different, snapshot: original))
        #expect(!WindowTargeting.matchesCaptureSnapshot(moved, snapshot: original))
        #expect(!WindowTargeting.matchesCaptureSnapshot(resized, snapshot: original))
        #expect(!WindowTargeting.matchesCaptureSnapshot(nil, snapshot: original))
    }

    @Test func hidingFinishesContactAndIgnoresItsLateDrag() throws {
        let canvas = StrokeCanvas()
        let view = InkLayerView(canvas: canvas)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: NSPoint(x: 10, y: 20), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: down)
        view.finishContact()
        #expect(canvas.strokes.count == 1)
        #expect(canvas.current == nil)
        view.mouseDragged(with: down)
        view.finishContact()
        #expect(canvas.strokes.count == 1)
    }

    @Test func penMouseOrdersContactAndReleasesAtFinalPosition() throws {
        var state = TabletMouseState()
        let a = CGPoint(x: 10, y: 20), b = CGPoint(x: 30, y: 40), c = CGPoint(x: 50, y: 60)
        let downEvents = state.update(position: a, tip: true)
        let down = try #require(downEvents.first)
        #expect(down.0 == .leftMouseDown && down.1 == a)
        let heldEvents = state.update(position: a, tip: true)
        #expect(heldEvents.isEmpty)
        let dragEvents = state.update(position: b, tip: true)
        let drag = try #require(dragEvents.first)
        #expect(drag.0 == .leftMouseDragged && drag.1 == b)
        let upEvents = state.update(position: c, tip: false)
        let up = try #require(upEvents.first)
        #expect(up.0 == .leftMouseUp && up.1 == c)
        let extraRelease = state.reset(at: c)
        #expect(extraRelease.map { _ in true } != true)
    }

    @Test func undoingActiveContactIgnoresLateMouseDrag() throws {
        let canvas = StrokeCanvas()
        let view = InkLayerView(canvas: canvas)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: NSPoint(x: 10, y: 20), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: down)
        canvas.undo()
        view.discardContact()
        view.mouseDragged(with: down)
        #expect(!canvas.hasContent)
        view.mouseDown(with: down)
        #expect(canvas.current != nil)
    }

    @Test func undoingPenContactWaitsForLiftBeforeNewStroke() throws {
        let canvas = StrokeCanvas()
        let view = InkLayerView(canvas: canvas)
        let point = Point(x: 10, y: 20)
        view.handleTabletPoint(location: point, pressure: 0.5, tip: true)
        #expect(canvas.current != nil)
        canvas.undo()
        view.discardContact()
        view.handleTabletPoint(location: Point(x: 20, y: 30), pressure: 0.5, tip: true)
        #expect(!canvas.hasContent)

        view.handleTabletPoint(location: point, pressure: 0, tip: false)
        view.handleTabletPoint(location: point, pressure: 0.6, tip: true)
        #expect(canvas.current?.points.first?.isTablet == true)
        #expect(canvas.current?.points.first?.pressure == 0.6)
    }

    @Test func tabletSampleWithoutProximityEndsMouseAndKeepsContactsSeparate() throws {
        let canvas = StrokeCanvas()
        let view = InkLayerView(canvas: canvas)
        let mouse = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: NSPoint(x: 1, y: 2), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let point = Point(x: 10, y: 20)
        view.mouseDown(with: mouse)
        view.handleTabletPoint(location: point, pressure: 0.8, tip: true)
        #expect(canvas.strokes.count == 1)
        #expect(canvas.strokes[0].points.allSatisfy { !$0.isTablet })
        view.mouseDown(with: mouse)
        view.mouseDragged(with: mouse)
        view.mouseUp(with: mouse)
        #expect(canvas.current?.points.allSatisfy { $0.isTablet } == true)
        view.handleTabletPoint(location: point, pressure: 0, tip: false)
        #expect(canvas.strokes.count == 2)
    }

    @Test func penProximityExitFinishesAtLastRealSample() throws {
        let canvas = StrokeCanvas()
        let view = InkLayerView(canvas: canvas)
        let last = Point(x: 20, y: 30)
        view.handleTabletPoint(location: Point(x: 10, y: 15), pressure: 0.3, tip: true)
        view.handleTabletPoint(location: last, pressure: 0.7, tip: true)
        view.updateTabletProximity(isEntering: false, location: Point(x: 1000, y: 2000))
        let stroke = try #require(canvas.strokes.first)
        #expect(stroke.points.last?.location == last)
        #expect(stroke.points.last?.pressure == 0.7)
        #expect(canvas.current == nil)
    }

    @Test func hidingAfterPenProximityAllowsMouseInNextSession() throws {
        let canvas = StrokeCanvas()
        let view = InkLayerView(canvas: canvas)
        let point = Point(x: 10, y: 20)
        view.updateTabletProximity(isEntering: true, location: point)
        view.finishContact()
        let mouse = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: NSPoint(x: 1, y: 2), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: mouse)
        view.mouseUp(with: mouse)
        #expect(canvas.strokes.count == 1)
        #expect(canvas.strokes[0].points.allSatisfy { !$0.isTablet })
    }

    @Test func penProximityCompletesAnInterruptedMouseStroke() throws {
        let canvas = StrokeCanvas()
        let view = InkLayerView(canvas: canvas)
        let mouse = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: NSPoint(x: 1, y: 2), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let point = Point(x: 10, y: 20)
        var notifications = 0
        view.onStrokeChanged = { notifications += 1 }
        view.mouseDown(with: mouse)
        view.updateTabletProximity(isEntering: true, location: point)
        #expect(canvas.current == nil)
        #expect(canvas.strokes.count == 1)
        #expect(canvas.strokes[0].points.allSatisfy { !$0.isTablet })
        view.mouseDragged(with: mouse)
        view.mouseUp(with: mouse)
        view.handleTabletPoint(location: point, pressure: 0.5, tip: true)
        view.handleTabletPoint(location: point, pressure: 0, tip: false)
        #expect(canvas.current == nil)
        #expect(canvas.strokes.count == 2)
        #expect(canvas.strokes[1].points.allSatisfy { $0.isTablet })
        #expect(notifications == 2)
    }

    @Test func penMouseResetReleasesOnceAndReestablishesPosition() throws {
        var state = TabletMouseState()
        let a = CGPoint(x: 10, y: 20), b = CGPoint(x: 30, y: 40)
        _ = state.update(position: a, tip: true)
        let releasedEvent = state.reset(at: b)
        let release = try #require(releasedEvent)
        #expect(release.0 == .leftMouseUp && release.1 == b)
        let extraRelease = state.reset(at: b)
        #expect(extraRelease.map { _ in true } != true)
        let hoverEvents = state.update(position: a, tip: false)
        let hover = try #require(hoverEvents.first)
        #expect(hover.0 == .mouseMoved && hover.1 == a)
    }

    @Test func loginFailureRestoresActualStateWithoutRecursiveRetries() throws {
        let suite = "PalimpsestTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var calls = 0
        let store = SettingsStore(defaults: defaults, updateLoginItem: { _ in
            calls += 1
            throw CocoaError(.fileWriteNoPermission)
        }, loginStatus: { .enabled })
        store.launchOnStartup = false
        #expect(calls == 1)
        #expect(store.launchOnStartup)
        #expect(store.startupMessage != nil)
        #expect(defaults.bool(forKey: "launch.onStartup"))
    }

    @Test func newDefaultsMatchOtherPlatformsAndExplicitPreferencesSurvive() throws {
        let suite = "PalimpsestTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = SettingsStore(defaults: defaults, updateLoginItem: { _ in }, loginStatus: { .notRegistered })
        #expect(fresh.action == .copyAndPaste)
        #expect(fresh.floatingPalettePosition == .topRight)
        defaults.set("clipboard", forKey: "delivery.action")
        defaults.set("none", forKey: "palette.floatingPosition")
        defaults.set(false, forKey: "history.saveAnnotations")
        let existing = SettingsStore(defaults: defaults, updateLoginItem: { _ in }, loginStatus: { .notRegistered })
        #expect(existing.action == .clipboard)
        #expect(existing.floatingPalettePosition == .none)
        #expect(!existing.saveAnnotations)
    }

    @Test func invalidStoredHotkeysFallBackWithoutCrashing() throws {
        let suite = "PalimpsestTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for (code, modifiers) in [(-1, 1), (Int(UInt32.max) + 1, 1), (2, 0), (2, 16), (55, 1)] {
            defaults.set(code, forKey: "hotkey.keyCode")
            defaults.set(modifiers, forKey: "hotkey.modifiers")
            let store = SettingsStore(defaults: defaults, updateLoginItem: { _ in }, loginStatus: { .notRegistered })
            #expect(store.hotkey == .standard)
        }
        defaults.set(0, forKey: "hotkey.keyCode")
        defaults.set(1, forKey: "hotkey.modifiers")
        let valid = SettingsStore(defaults: defaults, updateLoginItem: { _ in }, loginStatus: { .notRegistered })
        #expect(valid.hotkey == Hotkey(keyCode: 0, modifiers: .command))
    }

    @Test func recolouringMovesNameWithoutLeavingOrphans() throws {
        let suite = "PalimpsestTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults, updateLoginItem: { _ in }, loginStatus: { .notRegistered })
        let original = RGBA(r: 1, g: 2, b: 3)
        let middle = RGBA(r: 4, g: 5, b: 6)
        let final = RGBA(r: 7, g: 8, b: 9)
        store.palette = Palette(colors: [original, original], index: 0)
        store.setName("Custom", for: original)
        store.replaceColour(at: 0, with: middle)
        #expect(store.customName(for: original) == "Custom")
        #expect(store.customName(for: middle) == "Custom")
        store.replaceColour(at: 0, with: final)
        #expect(store.customName(for: middle) == nil)
        #expect(store.customName(for: final) == "Custom")
        let other = RGBA(r: 10, g: 11, b: 12)
        store.replaceColour(at: 1, with: other)
        #expect(store.customName(for: original) == nil)
        #expect(store.customName(for: other) == "Custom")
        store.setName("Existing", for: final)
        store.replaceColour(at: 1, with: final)
        #expect(store.palette.colors[1] == other)
        #expect(store.customName(for: final) == "Existing")
    }

    @Test func exportsAtSameInstantDoNotOverwriteEachOther() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PalimpsestTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = AnnotationHistory(folder: folder, now: { Date(timeIntervalSince1970: 0) })
        let firstData = Data([1, 2, 3]), secondData = Data([4, 5, 6])
        let first = try #require(history.save(firstData))
        let second = try #require(history.save(secondData))
        #expect(first != second)
        #expect(try Data(contentsOf: first) == firstData)
        #expect(try Data(contentsOf: second) == secondData)
        #expect(history.files.count == 2)
    }
}

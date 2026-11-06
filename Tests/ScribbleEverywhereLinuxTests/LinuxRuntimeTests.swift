import Foundation
import Dispatch
import Glibc
import Testing
import PalimpsestCore
import CPalimpsestLinux
@testable import PalimpsestLinux

@Suite("Linux runtime boundaries")
struct LinuxRuntimeTests {
    @Test func historyPreservesExportsAtTheSameInstant() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = LinuxHistory(folder: directory.path)
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let firstImage = ImageBuffer(width: 1, height: 1, fill: .red)
        let secondImage = ImageBuffer(width: 1, height: 1, fill: .blue)
        let first = try #require(history.save(firstImage, at: instant))
        let second = try #require(history.save(secondImage, at: instant))
        #expect(first != second)
        #expect(try Data(contentsOf: URL(fileURLWithPath: first)) != Data(contentsOf: URL(fileURLWithPath: second)))
        #expect(history.files().count == 2)
    }

    @Test func clearCommandRemovesRetainedInkWhileIdle() {
        let daemon = LinuxDaemon(config: LinuxConfig())
        daemon.canvas.begin(at: StrokePoint(location: Point(x: 1, y: 1), pressure: 0, isTablet: false))
        daemon.canvas.end(at: StrokePoint(location: Point(x: 2, y: 2), pressure: 0, isTablet: false))
        #expect(daemon.handle(command: "clear") == "ok strokes=0")
        #expect(!daemon.canvas.hasContent)
    }

    @Test func closedPinnedTargetAsksForReselectionLikeWindows() {
        var config = LinuxConfig()
        #expect(config.pasteMenuTitle(pinAvailable: false) == "Previous window")
        config.pasteOverride = "0xabc"
        config.pasteOverrideName = "Notes"
        #expect(config.pasteMenuTitle(pinAvailable: true) == "Notes")
        #expect(config.pasteMenuTitle(pinAvailable: false) == "Notes — reselect")
        config.pasteOverrideName = nil
        #expect(config.pasteMenuTitle(pinAvailable: false) == "0xabc — reselect")
        #expect(config.pasteMenuTitle == "0xabc")
    }

    @Test func oldConfigAndPartialConfigsPreserveTheirValues() throws {
        let data = Data(##"{"paletteColors":["#123456FF"],"paletteIndex":0,"paperTone":false,"colourNames":{"#123456FF":"Mine"}}"##.utf8)
        let config = try JSONDecoder().decode(LinuxConfig.self, from: data)
        #expect(config.palette.current.hex == "#123456FF")
        #expect(config.names["#123456FF"] == "Mine")
        #expect(!config.softenPaper)
        #expect(config.deliveryAction == .copyAndPaste)
        #expect(config.saveToDisk)
        #expect(try JSONDecoder().decode(LinuxConfig.self, from: Data("{}".utf8)).palette == LinuxConfig().palette)
    }

    @Test func configAtomicRoundtripAndFailureAreReported() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json").path
        var config = LinuxConfig()
        config.annotationFolder = "/tmp/Ink with spaces"
        config.saveAnnotations = false
        #expect(config.store(at: file))
        #expect(!LinuxConfig.load(from: file).saveToDisk)
        #expect(LinuxConfig.load(from: file).historyFolder == config.historyFolder)
        #expect(!config.store(at: directory.path))
        #expect(!LinuxConfig.load(from: file).saveToDisk)
    }

    @Test func failedSettingsCommandRestoresThePreviousPreference() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let daemon = LinuxDaemon(config: LinuxConfig(), configPath: directory.path)
        #expect(daemon.handle(command: "action clipboard").hasPrefix("error:"))
        #expect(daemon.handle(command: "action") == "ok action=copyAndPaste")
        let originalInk = daemon.canvas.ink
        #expect(daemon.handle(command: "colour 1").hasPrefix("error:"))
        #expect(daemon.canvas.ink == originalInk)
    }

    @Test func closedCaptureTargetDoesNotFallBackToAnUnrelatedWindow() {
        let unrelated = HyprlandWindow(address: "0x99", frame: Rect(x: 0, y: 0, width: 100, height: 100))
        var activeCalls = 0
        let selected = LinuxDaemon.captureWindow(address: "0x12", client: { _ in nil }, active: {
            activeCalls += 1
            return unrelated
        })
        #expect(selected?.address == nil)
        #expect(activeCalls == 0)
        #expect(LinuxDaemon.captureWindow(address: nil, client: { _ in nil }, active: { unrelated })?.address == "0x99")
        #expect(LinuxDaemon.captureWindow(address: "0x99", client: { _ in unrelated }, active: { nil })?.address == "0x99")
    }

    @Test func selectingAnExistingReplacementPreservesBothColourNames() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = LinuxConfig()
        let first = config.palette.colors[0]
        let second = config.palette.colors[1]
        config.names = [first.hex: "First", second.hex: "Second"]
        let path = directory.appendingPathComponent("config.json").path
        let daemon = LinuxDaemon(config: config, configPath: path)
        #expect(daemon.handle(command: "colour-replace 0 \(second.hex)").hasPrefix("ok"))
        let stored = LinuxConfig.load(from: path)
        #expect(stored.palette.colors[0] == first)
        #expect(stored.palette.current == second)
        #expect(stored.names[first.hex] == "First")
        #expect(stored.names[second.hex] == "Second")
    }

    @Test func autostartRoundtripQuotesSpacesAndLiteralPercent() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ink.desktop").path
        #expect(LinuxAutostart.setEnabled(true, at: path, binary: "/tmp/Ink 100%/palimpsest-ink"))
        let entry = try String(contentsOfFile: path, encoding: .utf8)
        #expect(entry.contains("Exec=\"/tmp/Ink 100%%/palimpsest-ink\" daemon"))
        #expect(LinuxAutostart.setEnabled(false, at: path))
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(!LinuxAutostart.setEnabled(false, at: directory.path))
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(LinuxAutostart.desktopEntry(binary: "/tmp/invalid=name") == nil)
    }

    @Test func ppmRejectsInvalidDimensionsAndPreservesWhitespacePixels() throws {
        for header in ["P6\n-1 1\n255\n", "P6\n0 1\n255\n", "P6\n9223372036854775807 2\n255\n", "P6\n2 2\n255\n"] {
            #expect(PPMDecoder.decode(Data(header.utf8)) == nil)
        }
        var ppm = Data("P6\r\n1 1\r\n255\r\n".utf8)
        ppm.append(contentsOf: [10, 32, 13])
        let image = try #require(PPMDecoder.decode(ppm))
        #expect(image[0, 0] == RGBA(r: 10, g: 32, b: 13))
    }

    @Test func childStdoutAndStderrAreDrainedTogether() {
        let result = Shell.run("/bin/sh", arguments: ["-c", "head -c 262144 /dev/zero >&2; head -c 262144 /dev/zero"])
        #expect(result.status == 0)
        #expect(result.stdout.count == 262144)
        #expect(result.stderr.count == 262144)
    }

    @Test func stalledProcessAndInheritedPipesDoNotBlockTheDaemon() {
        for command in ["exec sleep 2", "sleep 2 & exit 0"] {
            let started = ProcessInfo.processInfo.systemUptime
            let result = Shell.run("/bin/sh", arguments: ["-c", command], timeout: 0.08)
            #expect(result.status == -1)
            #expect(ProcessInfo.processInfo.systemUptime - started < 1)
        }
    }

    @Test func childArgumentsArePassedLiterallyAndExitStatusIsPreserved() {
        let argument = "café $(not-a-command); spaces"
        let result = Shell.run("/bin/sh", arguments: ["-c", "printf '%s' \"$1\"; exit 7", "test", argument])
        #expect(result.status == 7)
        #expect(String(data: result.stdout, encoding: .utf8) == argument)
        #expect(result.stderr.isEmpty)
        let environment = Shell.run("/bin/sh", arguments: ["-c", "printf '%s' \"$PATH\""])
        #expect(environment.status == 0)
        #expect(String(data: environment.stdout, encoding: .utf8) == (env("PATH") ?? ""))
        #expect(Shell.run("/definitely-not-a-palimpsest-command", arguments: []).status == -1)
        #expect(Shell.run("/bin/sh", arguments: ["-c", "kill -TERM $$"]).status == 143)
        #expect(Shell.run("/bin/sh", arguments: ["-c", "kill -PIPE $$"]).status == 141)
    }

    @Test func socketLinePreservesFragmentedUTF8AndRejectsTruncation() throws {
        var pair: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        let writer = pair[1]
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            for byte in "ok café 🖊\n".utf8 {
                _ = LinuxSocketIO.sendAll(Data([byte]), to: writer)
                usleep(1_000)
            }
            _ = shutdown(writer, Int32(SHUT_WR))
            group.leave()
        }
        #expect(LinuxSocketIO.readLine(from: pair[0]) == "ok café 🖊")
        group.wait()
        #expect(LinuxSocketIO.readLine(from: pair[0]) == nil)
    }

    @Test func socketLineTransfersLargeRepliesAndEnforcesItsLimit() throws {
        var pair: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        let message = String(repeating: "é", count: 200_000)
        let writer = pair[1]
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            _ = LinuxSocketIO.sendAll(Data((message + "\n").utf8), to: writer)
            _ = shutdown(writer, Int32(SHUT_WR))
            group.leave()
        }
        let received = LinuxSocketIO.readLine(from: pair[0])
        #expect(received == message)
        if received == nil { _ = shutdown(pair[0], Int32(SHUT_RD)) }
        group.wait()

        var limited: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &limited) == 0)
        defer { close(limited[0]); close(limited[1]) }
        #expect(LinuxSocketIO.sendAll(Data("12345\n".utf8), to: limited[1]))
        #expect(LinuxSocketIO.readLine(from: limited[0], maxBytes: 4) == nil)
    }

    @Test func socketReadTimesOutWhenPeerDoesNotRespond() throws {
        var pair: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        try #require(LinuxSocketIO.setTimeout(50, option: SO_RCVTIMEO, fd: pair[0]))
        let start = Date()
        #expect(LinuxSocketIO.readLine(from: pair[0]) == nil)
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func failedOrUnconfirmedFocusNeverSendsPaste() {
        var sent = 0
        let failed = LinuxPaster(focus: { _ in false }, active: { "0x12" }, sendPaste: { sent += 1; return true }, timeout: 0)
        #expect(!failed.pasteSync(into: "0x12"))
        let unfocused = LinuxPaster(focus: { _ in true }, active: { "0x99" }, sendPaste: { sent += 1; return true }, timeout: 0)
        #expect(!unfocused.pasteSync(into: "0x12"))
        #expect(!unfocused.pasteSync(into: nil))
        #expect(sent == 0)
    }

    @Test func confirmedFocusSendsExactlyOnceAndReportsDeliveryFailure() {
        var sent = 0
        let paster = LinuxPaster(focus: { $0 == "0x12" }, active: { "0x12" }, sendPaste: { sent += 1; return false }, timeout: 0)
        #expect(!paster.pasteSync(into: "0x12"))
        #expect(sent == 1)
    }

    @Test func clipboardChecksExitStatusAndTimeout() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = ImageBuffer(width: 1, height: 1, pixels: [255, 0, 0, 255])
        let failed = try script("cat >/dev/null\nexit 7", in: directory, name: "failed")
        #expect(!LinuxClipboard(resolveTool: { failed.path }).writeNow(image: image, png: nil))
        let stalled = try script("exec sleep 5", in: directory, name: "stalled")
        #expect(!LinuxClipboard(resolveTool: { stalled.path }, timeout: 0.03).writeNow(image: image, png: nil))
        #expect(!LinuxClipboard(resolveTool: { nil }).writeNow(image: image, png: nil))
    }

    @Test func clipboardOffersTheActualEncodedPNGToTheProcess() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("received.png")
        let tool = try script("cat > '\(output.path)'", in: directory, name: "receiver")
        let image = ImageBuffer(width: 1, height: 1, pixels: [255, 0, 0, 255])
        #expect(LinuxClipboard(resolveTool: { tool.path }).writeNow(image: image, png: nil))
        #expect(Array(try Data(contentsOf: output).prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
    }

    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("palimpsest-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func script(_ body: String, in directory: URL, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}

@Suite("Linux contact lifecycle")
struct LinuxContactTests {
    private func event(_ kind: Int, id: Int32 = 1, x: Double = 10, y: Double = 20, pressed: Int32 = 0, code: UInt32 = 0, pressure: Double = 0.5) -> palimpsest_event {
        var event = palimpsest_event()
        event.kind = Int32(kind)
        event.output_id = -1
        event.touch_id = id
        event.x = x
        event.y = y
        event.pressed = pressed
        event.code = code
        event.pressure = pressure
        return event
    }

    @Test func canceledTouchDiscardsOnlyItsInkAndNextTouchCanDraw() {
        let daemon = LinuxDaemon(config: LinuxConfig())
        daemon.beginInputSession()
        daemon.handle(event(PALIMPSEST_EVENT_TOUCH_DOWN))
        daemon.handle(event(PALIMPSEST_EVENT_TOUCH_UP))
        daemon.handle(event(PALIMPSEST_EVENT_TOUCH_DOWN, id: 2))
        daemon.handle(event(PALIMPSEST_EVENT_TOUCH_CANCEL))
        #expect(daemon.canvas.strokes.count == 1)
        #expect(daemon.canvas.current == nil)
        daemon.handle(event(PALIMPSEST_EVENT_TOUCH_DOWN, id: 3))
        daemon.handle(event(PALIMPSEST_EVENT_TOUCH_UP, id: 3))
        #expect(daemon.canvas.strokes.count == 2)
    }

    @Test func foreignTouchesAndMouseCannotChangeTheOwnedTouch() {
        let daemon = LinuxDaemon(config: LinuxConfig())
        daemon.beginInputSession()
        daemon.handle(event(PALIMPSEST_EVENT_TOUCH_DOWN))
        daemon.handle(event(PALIMPSEST_EVENT_TOUCH_DOWN, id: 2, x: 999))
        daemon.handle(event(PALIMPSEST_EVENT_POINTER_MOTION, x: 888))
        daemon.handle(event(PALIMPSEST_EVENT_POINTER_BUTTON, pressed: 1, code: 0x110))
        daemon.handle(event(PALIMPSEST_EVENT_TOUCH_UP, id: 2))
        #expect(daemon.canvas.current?.points.count == 1)
        daemon.handle(event(PALIMPSEST_EVENT_TOUCH_UP))
        #expect(daemon.canvas.strokes.first?.points.last?.location == Point(x: 10, y: 20))
    }

    @Test func penProximityRejectsPalmAndSessionRestartKeepsFinishedInk() {
        let daemon = LinuxDaemon(config: LinuxConfig())
        daemon.beginInputSession()
        daemon.handle(event(PALIMPSEST_EVENT_TOUCH_DOWN))
        daemon.handle(event(PALIMPSEST_EVENT_TABLET_PROXIMITY, pressed: 1))
        #expect(!daemon.canvas.hasContent)
        daemon.finishInputSession()
        daemon.beginInputSession()
        daemon.handle(event(PALIMPSEST_EVENT_TOUCH_DOWN, id: 3))
        daemon.finishInputSession()
        #expect(daemon.canvas.strokes.count == 1)
        daemon.beginInputSession()
        #expect(daemon.canvas.strokes.count == 1)
        #expect(daemon.canvas.current == nil)
    }

    @Test func penLiftKeepsTheLastContactPressure() {
        let daemon = LinuxDaemon(config: LinuxConfig())
        daemon.beginInputSession()
        daemon.handle(event(PALIMPSEST_EVENT_TABLET_PROXIMITY, pressed: 1))
        daemon.handle(event(PALIMPSEST_EVENT_TABLET_PRESSURE, pressure: 0.8))
        daemon.handle(event(PALIMPSEST_EVENT_TABLET_DOWN))
        daemon.handle(event(PALIMPSEST_EVENT_TABLET_FRAME))
        daemon.handle(event(PALIMPSEST_EVENT_TABLET_PRESSURE, pressure: 0))
        daemon.handle(event(PALIMPSEST_EVENT_TABLET_UP))
        daemon.handle(event(PALIMPSEST_EVENT_TABLET_FRAME))
        #expect(daemon.canvas.strokes.first?.points.last?.pressure == 0.8)
    }

    @Test func keyboardFocusResetClearsModifiersAndDuplicatePressesDoNotStick() {
        let daemon = LinuxDaemon(config: LinuxConfig())
        daemon.beginInputSession()
        daemon.handle(event(PALIMPSEST_EVENT_TOUCH_DOWN))
        daemon.handle(event(PALIMPSEST_EVENT_TOUCH_UP))
        daemon.handle(event(PALIMPSEST_EVENT_KEY, pressed: 1, code: 29))
        daemon.handle(event(PALIMPSEST_EVENT_KEYBOARD_FOCUS_RESET))
        daemon.handle(event(PALIMPSEST_EVENT_KEY, pressed: 1, code: 44))
        daemon.drainActions()
        #expect(daemon.canvas.strokes.count == 1)

        daemon.handle(event(PALIMPSEST_EVENT_KEY, pressed: 1, code: 29))
        daemon.handle(event(PALIMPSEST_EVENT_KEY, pressed: 1, code: 29))
        daemon.handle(event(PALIMPSEST_EVENT_KEY, pressed: 0, code: 29))
        daemon.handle(event(PALIMPSEST_EVENT_KEY, pressed: 1, code: 44))
        daemon.drainActions()
        #expect(daemon.canvas.strokes.count == 1)

        // Focus entry replays held Ctrl keys; releasing one must not release
        // the other if the user is holding both.
        daemon.handle(event(PALIMPSEST_EVENT_KEYBOARD_FOCUS_RESET))
        daemon.handle(event(PALIMPSEST_EVENT_KEY, pressed: 1, code: 29))
        daemon.handle(event(PALIMPSEST_EVENT_KEY, pressed: 1, code: 97))
        daemon.handle(event(PALIMPSEST_EVENT_KEY, pressed: 0, code: 29))
        daemon.handle(event(PALIMPSEST_EVENT_KEY, pressed: 1, code: 44))
        daemon.drainActions()
        #expect(daemon.canvas.strokes.isEmpty)
    }
}

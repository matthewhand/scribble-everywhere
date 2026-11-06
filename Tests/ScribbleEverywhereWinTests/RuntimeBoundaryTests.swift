import Foundation
import Testing
import WinSDK
import PalimpsestCore
@testable import PalimpsestWin

@Suite("Windows runtime boundaries", .serialized)
@MainActor
struct RuntimeBoundaryTests {
    @Test func deliveryStatusReportsSaveAndPasteFailuresIndependently() {
        #expect(WinController.deliveryMessage(pasteSent: nil, saveFailed: false) == "Copied to clipboard")
        #expect(WinController.deliveryMessage(pasteSent: nil, saveFailed: true) == "Copied to clipboard; save failed")
        #expect(WinController.deliveryMessage(pasteSent: true, saveFailed: true) == "Copied — paste sent; save failed")
        #expect(WinController.deliveryMessage(pasteSent: false, saveFailed: true) == "Copied — paste failed; save failed")
        #expect(WinController.deliveryMessage(pasteSent: false, saveFailed: false) == "Copied — paste failed")
    }

    @Test func ownWindowsCannotBecomeExternalCaptureTargets() throws {
        let hwnd = try #require(CreateWindowExW(0, "STATIC".wide, "test".wide, 0,
                                                0, 0, 1, 1, nil, nil, GetModuleHandleW(nil), nil))
        defer { _ = DestroyWindow(hwnd) }
        #expect(WinWindowTargeting.externalWindow(hwnd) == nil)
        #expect(WinWindowTargeting.externalWindow(nil) == nil)
    }

    @Test func missingOrClosedRememberedTargetNeverFallsBackToAnotherWindow() throws {
        let identity = WinWindowTargeting.Identity(processId: 123, processCreation: 456, className: "Editor", title: "Document")
        #expect(WinWindowTargeting.rememberedCaptureTarget(nil, expected: identity)?.hwnd == nil)
        let hwnd = try #require(CreateWindowExW(0, "STATIC".wide, "temporary".wide, 0,
                                                0, 0, 1, 1, nil, nil, GetModuleHandleW(nil), nil))
        #expect(DestroyWindow(hwnd))
        #expect(WinWindowTargeting.rememberedCaptureTarget(hwnd, expected: identity)?.hwnd == nil)
    }

    @Test func historyRetainsMultipleSavesAtTheSameTimestamp() throws {
        let scratch = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("work/history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let history = WinHistory(folder: scratch.path)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try #require(history.save(png: Data([1]), at: date))
        let second = try #require(history.save(png: Data([2]), at: date))
        #expect(first != second)
        #expect(try Data(contentsOf: first) == Data([1]))
        #expect(try Data(contentsOf: second) == Data([2]))
        #expect(Set(history.files()) == Set([first, second]))
    }

    @Test func folderDiagnosticsUseSelectedFolderWithoutClobberingExistingFiles() throws {
        let scratch = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("work/diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let existing = scratch.appendingPathComponent(".write-test")
        try Data("user data".utf8).write(to: existing)
        #expect(WinDiagnostics.folderWriteStatus(scratch.path) == "Folder write: OK")
        #expect(try Data(contentsOf: existing) == Data("user data".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path) == [".write-test"])
        #expect(WinDiagnostics.folderWriteStatus(scratch.appendingPathComponent("missing").path).contains("FAILED"))
    }

    @Test func settingsKeyNamesValidateLettersDigitsAndFunctionKeys() {
        #expect(WinSettings.keyCode("d") == 0x44)
        #expect(WinSettings.keyCode("7") == 0x37)
        #expect(WinSettings.keyCode("F12") == UInt32(VK_F12))
        #expect(WinSettings.keyCode("Space") == UInt32(VK_SPACE))
        #expect(WinSettings.keyCode("F13") == nil)
        #expect(WinSettings.keyCode("") == nil)
        #expect(WinSettings.keyCode("not a key") == nil)
    }

    @Test func legacyShortcutMigrationPreservesCustomArgumentsAndForeignTargets() throws {
        let scratch = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("work/migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        func path(_ url: URL) -> String { url.path.replacingOccurrences(of: "/", with: "\\") }
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }
        let cases = [("PalimpsestWin.exe", "", "/startup"), ("ScribbleEverywhere.exe", "", "/startup"), ("PalimpsestWin.exe", "/custom", "/custom"), ("Other.exe", "", "")]
        for (index, entry) in cases.enumerated() {
            let shortcut = path(scratch.appendingPathComponent("case\(index).lnk"))
            let executable = path(scratch.appendingPathComponent(entry.0))
            let result = scratch.appendingPathComponent("result\(index).json")
            let script = WinAutostart.shortcutScript(shortcutPath: shortcut, executablePath: executable) + "\n" + """
            $s.Arguments = \(quote(entry.1))
            $s.Save()
            """ + "\n" + WinAutostart.migrationScript(shortcutPath: shortcut) + "\n" + """
            $s = (New-Object -ComObject WScript.Shell).CreateShortcut(\(quote(shortcut)))
            [IO.File]::WriteAllText(\(quote(path(result))), ($s | Select-Object TargetPath, Arguments | ConvertTo-Json))
            """
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "\(env("SystemRoot") ?? "C:\\Windows")\\System32\\WindowsPowerShell\\v1.0\\powershell.exe")
            process.arguments = ["-NoProfile", "-NonInteractive", "-Command", script]
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)
            let values = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: result)) as? [String: String])
            #expect(values["Arguments"] == entry.2)
            #expect(values["TargetPath"]?.lowercased() == executable.lowercased())
        }
    }

    @Test func captureReturnsTheRequestedSizeAndOpaquePixels() throws {
        let display = try #require(WinDisplays.all().first)
        let result = try WinScreenCapturer().captureWithGeometry(rect: Rect(
            x: display.frame.minX + 1, y: display.frame.minY + 1, width: 4, height: 3
        ))
        let image = result.image
        #expect(image.width == 4)
        #expect(image.height == 3)
        #expect(result.origin == Point(x: display.frame.minX + 1, y: display.frame.minY + 1))
        #expect(result.scale == display.scale)
        #expect(stride(from: 3, to: image.pixels.count, by: 4).allSatisfy { image.pixels[$0] == 255 })
    }

    @Test func captureReportsClippedScreenOriginForInkPlacement() throws {
        let display = try #require(WinDisplays.all().first)
        let result = try WinScreenCapturer().captureWithGeometry(rect: Rect(
            x: display.frame.minX - 2, y: display.frame.minY + 1, width: 6, height: 3
        ))
        #expect(result.image.width == 4)
        #expect(result.image.height == 3)
        #expect(result.origin == Point(x: display.frame.minX, y: display.frame.minY + 1))
        #expect(result.scale == display.scale)
    }

    @Test func pasteMessagePumpPreservesQuitAndItsExitCode() {
        PostQuitMessage(37)
        WinPaster.pumpOnce()
        var message = MSG()
        #expect(PeekMessageW(&message, nil, UINT(WM_QUIT), UINT(WM_QUIT), UINT(PM_REMOVE)))
        #expect(message.wParam == 37)
    }

    @Test func startupShortcutActuallyPreservesQuotedPathsAndIdleLaunch() throws {
        // Exercise the real COM shortcut writer in scratch space, never Startup.
        let scratch = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("work/runtime-\(UUID().uuidString)")
        let directory = scratch.appendingPathComponent("O'Brien")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        func windowsPath(_ url: URL) -> String { url.path.replacingOccurrences(of: "/", with: "\\") }
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
        let executable = windowsPath(directory.appendingPathComponent("Ink.exe"))
        let shortcut = windowsPath(scratch.appendingPathComponent("Ink's startup.lnk"))
        let result = scratch.appendingPathComponent("shortcut.json")
        let script = WinAutostart.shortcutScript(shortcutPath: shortcut, executablePath: executable) + "\n" + """
        $s = (New-Object -ComObject WScript.Shell).CreateShortcut(\(quoted(shortcut)))
        [IO.File]::WriteAllText(\(quoted(windowsPath(result))), ($s | Select-Object TargetPath, Arguments, WorkingDirectory | ConvertTo-Json))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "\(env("SystemRoot") ?? "C:\\Windows")\\System32\\WindowsPowerShell\\v1.0\\powershell.exe")
        process.arguments = ["-NoProfile", "-NonInteractive", "-Command", script]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        let values = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: result)) as? [String: String])
        #expect(values["TargetPath"]?.lowercased() == executable.lowercased())
        #expect(values["WorkingDirectory"]?.lowercased() == windowsPath(directory).lowercased())
        #expect(values["Arguments"] == "/startup")
    }
}

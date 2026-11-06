import Foundation
import WinSDK
import PalimpsestCore

/// Saves delivered annotations as PNGs and lists recent files.
@MainActor
final class WinHistory {
    private var folder: String

    init(folder: String) {
        self.folder = folder
        ensureFolder()
    }

    func setFolder(_ folder: String) {
        self.folder = folder
        ensureFolder()
    }

    nonisolated static func defaultFolder() -> String {
        let base = env("APPDATA") ?? "."
        return "\(base)\\PalimpsestInk\\Annotations"
    }

    private func ensureFolder() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: folder) {
            try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
    }

    /// Save `png` to an ISO8601-named file. Returns the URL if successful.
    func save(png: Data, at date: Date = Date()) -> URL? {
        ensureFolder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Multiple saves can happen in the same millisecond. A unique suffix
        // prevents a later annotation from replacing an earlier one.
        let name = "Annotation \(formatter.string(from: date).replacingOccurrences(of: ":", with: "-")) \(UUID().uuidString).png"
        let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
        do {
            try png.write(to: url, options: .atomic)
            WinLog.log("history saved \(url.path)")
            return url
        } catch {
            WinLog.log("history save failed \(error)")
            return nil
        }
    }

    /// List PNGs newest-first.
    func files() -> [URL] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: folder) else { return [] }
        return contents
            .filter { $0.lowercased().hasSuffix(".png") }
            .map { URL(fileURLWithPath: folder).appendingPathComponent($0) }
            .sorted {
                ($0.contentModificationDate ?? .distantPast) > ($1.contentModificationDate ?? .distantPast)
            }
    }

    /// Open the folder or a specific file in Explorer.
    func reveal(_ url: URL?) {
        let target = url ?? URL(fileURLWithPath: folder)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "\(env("SystemRoot") ?? "C:\\Windows")\\explorer.exe")
        let path = target.path.replacingOccurrences(of: "/", with: "\\")
        task.arguments = url == nil ? [path] : ["/select,", path]
        do { try task.run() } catch { WinLog.log("Open history failed: \(error)") }
    }
}

private extension URL {
    var contentModificationDate: Date? {
        try? resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

/// Launch-at-login via the Startup folder.
@MainActor
final class WinAutostart {
    static func migrateExistingShortcut() -> Bool {
        guard isEnabled() else { return true }
        return runPowershell(migrationScript(shortcutPath: shortcutPath()))
    }

    /// Repair only this app's legacy empty-argument link. Preserve custom
    /// arguments, target paths and links belonging to another executable.
    static func migrationScript(shortcutPath: String) -> String {
        let path = "'" + shortcutPath.replacingOccurrences(of: "'", with: "''") + "'"
        return """
        $ErrorActionPreference = 'Stop'
        if (Test-Path -LiteralPath \(path)) {
            $s = (New-Object -ComObject WScript.Shell).CreateShortcut(\(path))
            if ([IO.Path]::GetFileName($s.TargetPath) -in @('PalimpsestWin.exe', 'ScribbleEverywhere.exe') -and [string]::IsNullOrWhiteSpace($s.Arguments)) {
                $s.Arguments = '/startup'
                $s.Save()
            }
        }
        """
    }

    static func isEnabled() -> Bool {
        let path = shortcutPath()
        return FileManager.default.fileExists(atPath: path)
    }

    static func setEnabled(_ on: Bool) -> Bool {
        let path = shortcutPath()
        if on {
            let dest = exePath()
            guard !dest.isEmpty else { return false }
            guard runPowershell(shortcutScript(shortcutPath: path, executablePath: dest)) else { return false }
        } else {
            do {
                if FileManager.default.fileExists(atPath: path) {
                    try FileManager.default.removeItem(atPath: path)
                }
            } catch {
                WinLog.log("Remove startup shortcut failed: \(error)")
                return false
            }
        }
        return isEnabled() == on
    }

    /// PowerShell single-quoted literals preserve backslashes; only apostrophes
    /// need escaping. /startup prevents annotation from opening during login.
    static func shortcutScript(shortcutPath: String, executablePath: String) -> String {
        func quoted(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        }
        let directory = URL(fileURLWithPath: executablePath).deletingLastPathComponent().path
            .replacingOccurrences(of: "/", with: "\\")
        return """
        $ErrorActionPreference = 'Stop'
        $s = (New-Object -ComObject WScript.Shell).CreateShortcut(\(quoted(shortcutPath)))
        $s.TargetPath = \(quoted(executablePath))
        $s.Arguments = '/startup'
        $s.WorkingDirectory = \(quoted(directory))
        $s.Save()
        """
    }

    private static func shortcutPath() -> String {
        let base = env("APPDATA") ?? "."
        return "\(base)\\Microsoft\\Windows\\Start Menu\\Programs\\Startup\\Palimpsest Ink.lnk"
    }

    private static func exePath() -> String {
        var buffer = [WCHAR](repeating: 0, count: 1024)
        let count = GetModuleFileNameW(GetModuleHandleW(nil), &buffer, UInt32(buffer.count))
        guard count > 0, count < UInt32(buffer.count) else { return "" }
        return String(decoding: buffer.prefix(Int(count)).map { UInt16($0) }, as: UTF16.self)
    }

    private static func runPowershell(_ script: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "\(env("SystemRoot") ?? "C:\\Windows")\\System32\\WindowsPowerShell\\v1.0\\powershell.exe")
        task.arguments = ["-NoProfile", "-Command", script]
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            WinLog.log("Startup shortcut update failed: \(error)")
            return false
        }
    }
}

/// Built-in colour names (mirror macOS ColourNames).
enum WinColourNames {
    private static let known: [(RGBA, String)] = [
        (RGBA(r: 255, g: 59, b: 48), "Red"),
        (RGBA(r: 0, g: 122, b: 255), "Blue"),
        (RGBA(r: 52, g: 199, b: 89), "Green"),
        (RGBA(r: 255, g: 149, b: 0), "Orange"),
        (RGBA(r: 175, g: 82, b: 222), "Purple"),
        (RGBA(r: 255, g: 214, b: 10), "Yellow"),
        (RGBA(r: 90, g: 200, b: 250), "Cyan"),
        (RGBA(r: 255, g: 45, b: 85), "Pink"),
        (RGBA(r: 255, g: 255, b: 255), "White"),
        (RGBA(r: 0, g: 0, b: 0), "Black")
    ]

    static func name(for color: RGBA) -> String {
        known.first { $0.0 == color }?.1 ?? color.hex
    }

    /// Colours not in the palette that can be offered for "Add".
    static func extras(current: [RGBA]) -> [RGBA] {
        known.map { pair in pair.0 }.filter { c in !current.contains(c) }
    }
}

/// Permission / dependency check shown in the tray menu.
@MainActor
enum WinDiagnostics {
    static func run(annotationFolder: String) -> String {
        var lines: [String] = []
        // Opening the clipboard is non-destructive; it does not prove that a
        // later write or paste will succeed, so report only availability.
        if OpenClipboard(nil) {
            _ = CloseClipboard()
            lines.append("Clipboard: available (write not tested)")
        } else {
            lines.append("Clipboard: currently unavailable")
        }
        lines.append(folderWriteStatus(annotationFolder))
        lines.append("Hotkey: \(WinController.hotkeyStatus)")
        return lines.joined(separator: "\n")
    }

    static func folderWriteStatus(_ folder: String) -> String {
        // Avoid reusing a fixed filename such as a prior .write-test.
        let testURL = URL(fileURLWithPath: folder).appendingPathComponent(".palimpsest-write-test-\(UUID().uuidString)")
        do {
            try "test".write(to: testURL, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: testURL)
            return "Folder write: OK"
        } catch {
            return "Folder write: FAILED (\(error.localizedDescription))"
        }
    }
}

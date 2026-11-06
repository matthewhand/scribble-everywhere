import Foundation
import WinSDK

/// Coordinates launches from user-configured pen shortcuts without changing
/// Windows pen or handwriting settings.
enum WinPenShortcut {
    static var openOnLaunch = false
    static var openSettingsOnLaunch = false

    private static var instanceMutex: HANDLE?

    /// Returns false when another instance is already running. In that case this
    /// process has asked it to toggle and should exit.
    static func becomePrimary() -> Bool {
        // PenService launches the exe with no arguments. The Startup shortcut
        // passes /startup so logging in does not turn annotation on.
        let tail = CommandLine.arguments.dropFirst().map { $0.lowercased() }
        let fromStartup = tail.contains("/startup") || tail.contains("--startup")
        let settings = tail.contains("/settings") || tail.contains("--settings")
        let fromPen = !fromStartup && !settings
        let name = "Local\\PalimpsestInk".wide
        instanceMutex = name.withUnsafeBufferPointer { raw in
            CreateMutexW(nil, false, raw.baseAddress)
        }
        let existing = GetLastError() == DWORD(183)
        if existing {
            let posted = settings ? signalRunningInstance(message: WinController.WM_APP_OPEN_SETTINGS, parameter: 0)
                : (fromPen ? signalRunningInstance() : true)
            WinLog.log("second launch intent=\(settings ? "settings" : (fromPen ? "toggle" : "startup")) signaled=\(posted)")
            return false
        }
        openOnLaunch = fromPen
        openSettingsOnLaunch = settings
        return true
    }

    /// Called once the tray window exists. A later pen click starts a second
    /// process, which posts the toggle here instead of enumerating windows.
    static func noteTrayWindow(_ hwnd: HWND) {
        let bits = UInt(bitPattern: Int(bitPattern: hwnd))
        let url = instanceURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(String(bits).utf8).write(to: url)
    }

    private static func signalRunningInstance(message: UINT = UINT(WM_HOTKEY), parameter: WPARAM = WPARAM(UInt(SurfacePenButton.hotkeyId))) -> Bool {
        let url = instanceURL()
        for _ in 0..<30 {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let bits = UInt(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                let hwnd = HWND(bitPattern: Int(bitPattern: bits))
                var className = [WCHAR](repeating: 0, count: 128)
                if GetClassNameW(hwnd, &className, Int32(className.count)) > 0,
                   className.string == "PalimpsestTrayWindow" {
                    return PostMessageW(hwnd, message, parameter, 0)
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private static func instanceURL() -> URL {
        URL(fileURLWithPath: WinLog.logDirectory()).appendingPathComponent("instance.txt")
    }

}

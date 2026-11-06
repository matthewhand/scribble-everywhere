import Foundation
import WinSDK
import PalimpsestCore

/// A single Windows display in the core's top-left-origin global space.
/// Virtual-screen coordinates are already top-left-origin, so no flipping is
/// needed - unlike macOS.
enum WinDisplays {
    struct Info {
        var id: UInt32
        var frame: Rect
        var scale: Double
    }

    /// Enumerates monitors via EnumDisplayMonitors. `hdc` is unused (nullptr).
    static func all() -> [Info] {
        var results: [Info] = []
        withUnsafeMutablePointer(to: &results) { pointer in
            // Win32 order is (HMONITOR, HDC, LPRECT, LPARAM). The names in the
            // scaffold were swapped, so the third argument is the clip rect.
            _ = EnumDisplayMonitors(nil, nil, { monitor, _, _, data in
                guard let monitor else { return true }
                let results = UnsafeMutablePointer<[Info]>(bitPattern: Int(data))
                guard let results else { return true }

                var info = MONITORINFOEXW()
                info.cbSize = UInt32(MemoryLayout<MONITORINFOEXW>.size)
                // GetMonitorInfoW writes a MONITORINFOEX when cbSize says so.
                // Swift types the parameter as MONITORINFO, so rebind the same storage.
                let gotInfo = withUnsafeMutableBytes(of: &info) { raw -> Bool in
                    guard let base = raw.baseAddress else { return false }
                    return GetMonitorInfoW(monitor, base.assumingMemoryBound(to: MONITORINFO.self))
                }
                guard gotInfo else { return true }

                // Shcore is not always loaded; LoadLibrary so GetDpiForMonitor resolves.
                var dpiX: UINT = 96, dpiY: UINT = 96
                if let shcore = LoadLibraryW("Shcore.dll".wide) {
                    defer { FreeLibrary(shcore) }
                    let getDpi = unsafeBitCast(
                        GetProcAddress(shcore, "GetDpiForMonitor"),
                        to: (@convention(c) (HMONITOR, MONITOR_DPI_TYPE, UnsafeMutablePointer<UINT>, UnsafeMutablePointer<UINT>) -> HRESULT)?.self
                    )
                    if let getDpi {
                        _ = getDpi(monitor, MDT_EFFECTIVE_DPI, &dpiX, &dpiY)
                    }
                }

                let frame = Rect(
                    x: Double(info.rcMonitor.left),
                    y: Double(info.rcMonitor.top),
                    width: Double(info.rcMonitor.right - info.rcMonitor.left),
                    height: Double(info.rcMonitor.bottom - info.rcMonitor.top)
                )
                let id = UInt32(truncatingIfNeeded: UInt(bitPattern: monitor))
                results.pointee.append(Info(id: id, frame: frame, scale: Double(dpiX) / 96.0))
                return true
            }, LPARAM(Int(bitPattern: pointer)))
        }
        return results
    }

    static func display(containing point: Point) -> Info? {
        all().first { $0.frame.contains(point) }
    }
}

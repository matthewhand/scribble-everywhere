import AppKit
import PalimpsestCore
import CoreGraphics

struct WindowTarget {
    var identity: WindowIdentity
    var frame: Rect
    var applicationName: String?
    var bundleIdentifier: String?
}

struct WindowIdentity: Equatable {
    var windowID: CGWindowID
    var processID: pid_t
}

enum WindowTargeting {
    /// The menu-bar app itself can be frontmost when annotation is started
    /// from its menu. In that case the previous app is the external window.
    static func previousApplication(frontmost: String?, own: String?, target: String?) -> String? {
        guard let frontmost, frontmost != own else { return target }
        return frontmost
    }

    /// A missing or invalid chosen app must not silently redirect the paste to
    /// a different app. The clipboard remains available if no target exists.
    static func deliveryApplication(preference: PasteTargetPreference, previous: String?, frontmost: String?, pinned: String?, own: String?) -> String? {
        let candidate = pinned ?? (preference == .previousApp ? previous : frontmost)
        guard let candidate, !candidate.isEmpty, candidate != own else { return nil }
        return candidate
    }

    static func matchesSession(_ target: WindowIdentity?, session: WindowIdentity?) -> Bool {
        guard let target, let session else { return false }
        return target == session
    }

    static func canCompleteCapture(requiresSession: Bool, isCapturing: Bool, current: WindowTarget?, snapshot: WindowTarget, session: WindowIdentity?) -> Bool {
        matchesCaptureSnapshot(current, snapshot: snapshot)
            && (!requiresSession || (isCapturing && matchesSession(current?.identity, session: session)))
    }

    static func matchesCaptureSnapshot(_ current: WindowTarget?, snapshot: WindowTarget) -> Bool {
        guard let current else { return false }
        return current.identity == snapshot.identity && current.frame == snapshot.frame
    }

    /// Every on-screen regular window, one entry per application (the applet
    /// menu lists apps, not windows), excluding our own process. Sorted by name.
    static func visibleWindows() -> [WindowTarget] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        var byBundle: [String: WindowTarget] = [:]
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID else { continue }
            guard let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let width = bounds["Width"] ?? 0
            let height = bounds["Height"] ?? 0
            guard width > 1, height > 1 else { continue }

            let app = NSRunningApplication(processIdentifier: pid)
            guard let bundleID = app?.bundleIdentifier, !bundleID.isEmpty else { continue }
            let target = WindowTarget(
                identity: WindowIdentity(windowID: windowID, processID: pid),
                frame: Rect(
                    x: Double(bounds["X"] ?? 0),
                    y: Double(bounds["Y"] ?? 0),
                    width: Double(width),
                    height: Double(height)
                ),
                applicationName: info[kCGWindowOwnerName as String] as? String,
                bundleIdentifier: bundleID
            )
            // Keep the largest window per app (the "main" one).
            if let existing = byBundle[bundleID] {
                if target.frame.size.width * target.frame.size.height > existing.frame.size.width * existing.frame.size.height {
                    byBundle[bundleID] = target
                }
            } else {
                byBundle[bundleID] = target
            }
        }
        return byBundle.values.sorted {
            ($0.applicationName ?? $0.bundleIdentifier ?? "")
                .localizedCaseInsensitiveCompare(
                    $1.applicationName ?? $1.bundleIdentifier ?? ""
                ) == .orderedAscending
        }
    }

    /// The frontmost on-screen window that is not ours and is not the desktop.
    static func frontmostWindow() -> WindowTarget? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID else { continue }
            guard let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let width = bounds["Width"] ?? 0
            let height = bounds["Height"] ?? 0
            guard width > 1, height > 1 else { continue }

            let frame = Rect(
                x: Double(bounds["X"] ?? 0),
                y: Double(bounds["Y"] ?? 0),
                width: Double(width),
                height: Double(height)
            )
            let app = NSRunningApplication(processIdentifier: pid)
            return WindowTarget(
                identity: WindowIdentity(windowID: windowID, processID: pid),
                frame: frame,
                applicationName: info[kCGWindowOwnerName as String] as? String,
                bundleIdentifier: app?.bundleIdentifier
            )
        }
        return nil
    }
}

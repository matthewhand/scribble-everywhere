import AppKit
import ApplicationServices
import CoreGraphics
import PalimpsestCore

/// Reactivates the target application and sends ⌘V. Requires Accessibility
/// permission; without it we cannot synthesise keystrokes, so we report the
/// failure instead of pretending the paste happened.
@MainActor
final class Paster: PalimpsestCore.Paster {
    private let log: (String) -> Void
    private let isTrusted: () -> Bool
    private let activate: (String, pid_t?) async -> Bool
    private let sendPaste: () -> Bool

    init(log: @escaping (String) -> Void = { Diagnostics.log($0) },
         isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         activate: ((String) async -> Bool)? = nil,
         activateProcess: ((String, pid_t?) async -> Bool)? = nil,
         sendPaste: (() -> Bool)? = nil) {
        self.log = log
        self.isTrusted = isTrusted
        if let activateProcess {
            self.activate = activateProcess
        } else if let activate {
            self.activate = { id, _ in await activate(id) }
        } else {
            self.activate = { id, processID in await Self.activateTarget(id, expectedProcessID: processID) }
        }
        self.sendPaste = sendPaste ?? { Self.postCommandV() }
    }

    @discardableResult
    func paste(into applicationID: String?) async -> Bool {
        await paste(into: applicationID, expectedProcessID: nil)
    }

    @discardableResult
    func paste(into applicationID: String?, expectedProcessID: pid_t?) async -> Bool {
        guard isTrusted() else {
            log("Accessibility permission not granted; cannot send ⌘V")
            return false
        }

        guard let applicationID, !applicationID.isEmpty else {
            log("No target application to paste into; skipping ⌘V")
            return false
        }

        guard await activate(applicationID, expectedProcessID), !Task.isCancelled else {
            log("Target application did not activate; skipping ⌘V")
            return false
        }
        return sendPaste()
    }

    private static func activateTarget(_ applicationID: String, expectedProcessID: pid_t?) async -> Bool {
        let app = expectedProcessID.flatMap { NSRunningApplication(processIdentifier: $0) }
            ?? (expectedProcessID == nil ? NSRunningApplication.runningApplications(withBundleIdentifier: applicationID).first : nil)
        guard let app, app.bundleIdentifier == applicationID,
              !app.isTerminated, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        await NSApp.yieldActivation(to: app)
        app.activate(options: [])
        let timeout: TimeInterval = 1.5
        let deadline = Date().addingTimeInterval(timeout)
        while !app.isActive, Date() < deadline {
            do { try await Task.sleep(nanoseconds: 30_000_000) }
            catch { return false }
            if app.isTerminated { return false }
        }
        return app.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    private static func postCommandV() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode: CGKeyCode = 9 // V
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}

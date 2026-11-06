import Foundation
import Glibc
import PalimpsestCore
import CPalimpsestLinux

/// wl-copy's parent exits successfully once its background selection owner is
/// ready. A failed or timed-out write must never be followed by a stale paste.
final class LinuxClipboard: ClipboardWriter {
    private let resolveTool: () -> String?
    private let timeout: TimeInterval

    init(resolveTool: @escaping () -> String? = { Tools.path("wl-copy") }, timeout: TimeInterval = 2) {
        self.resolveTool = resolveTool
        self.timeout = timeout
    }

    func write(image: ImageBuffer, png: Data?) { _ = writeNow(image: image, png: png) }

    @discardableResult
    func writeNow(image: ImageBuffer, png: Data?) -> Bool {
        guard let tool = resolveTool() else {
            LinuxLog.log("wl-copy is not installed")
            return false
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("palimpsest-clipboard-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let imageURL = directory.appendingPathComponent("image.png")
            if let png {
                try png.write(to: imageURL)
            } else {
                let wrote = image.withRawBytes { pointer in
                    palimpsest_write_png_rgba(imageURL.path, Int32(image.width), Int32(image.height),
                        Int32(image.width * 4), pointer.assumingMemoryBound(to: UInt8.self)) == 0
                }
                guard wrote else { return false }
            }
            let input = try FileHandle(forReadingFrom: imageURL)
            defer { try? input.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = ["-t", "image/png"]
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline { usleep(10_000) }
            if process.isRunning {
                process.terminate()
                usleep(20_000)
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                LinuxLog.log("wl-copy timed out; paste suppressed")
                return false
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                LinuxLog.log("wl-copy failed status=\(process.terminationStatus); paste suppressed")
                return false
            }
            return true
        } catch {
            LinuxLog.log("Clipboard write failed: \(error)")
            return false
        }
    }
}

/// Refocuses a specific Hyprland address and verifies it before sending Ctrl+V.
final class LinuxPaster: Paster {
    private let focus: (String) -> Bool
    private let active: () -> String?
    private let sendPaste: () -> Bool
    private let timeout: TimeInterval

    init(focus: @escaping (String) -> Bool = { address in
            guard let tool = Tools.path("hyprctl") else { return false }
            return Shell.run(tool, arguments: ["dispatch", "focuswindow", "address:\(address)"]).status == 0
         },
         active: @escaping () -> String? = { HyprlandWindow.active()?.address },
         sendPaste: @escaping () -> Bool = {
            guard let tool = Tools.path("wtype") else { return false }
            return Shell.run(tool, arguments: ["-M", "ctrl", "v", "-m", "ctrl"]).status == 0
         }, timeout: TimeInterval = 0.6) {
        self.focus = focus
        self.active = active
        self.sendPaste = sendPaste
        self.timeout = timeout
    }

    func paste(into applicationID: String?) async -> Bool { pasteSync(into: applicationID) }

    @discardableResult
    func pasteSync(into applicationID: String?) -> Bool {
        guard let address = applicationID, !address.isEmpty, focus(address) else {
            LinuxLog.log("Paste target unavailable; Ctrl+V suppressed")
            return false
        }
        let deadline = Date().addingTimeInterval(timeout)
        while active() != address && Date() < deadline { usleep(20_000) }
        guard active() == address else {
            LinuxLog.log("Paste target did not become active; Ctrl+V suppressed")
            return false
        }
        return sendPaste()
    }
}

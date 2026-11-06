import Foundation
import Glibc
import PalimpsestCore
import CPalimpsestLinux

/// `palimpsest-ink daemon` runs the overlay. Any other command talks to it
/// over a Unix socket and starts the daemon if it is not already running.
@main
struct PalimpsestLinuxApp {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            print(usage)
            exit(2)
        }

        switch command {
        case "daemon":
            let daemon = LinuxDaemon()
            guard daemon.connect() else { exit(1) }
            daemon.run()
        case "help", "--help", "-h":
            print(usage)
        case "version", "--version":
            print(PalimpsestVersion.displayString)
        case "self-test":
            let failures = LinuxSelfTest.run()
            if failures.isEmpty {
                print("ok")
                exit(0)
            }
            for failure in failures { fputs(failure + "\n", stderr) }
            exit(1)
        default:
            let reply = sendOrStart(arguments: arguments)
            if arguments.contains("--waybar"), reply.contains("annotating=") {
                print(waybarJSON(reply: reply))
            } else {
                print(reply)
            }
            exit(reply.hasPrefix("ok") || reply.hasPrefix("{") || reply.contains("annotating=") ? 0 : 1)
        }
    }

    static func waybarJSON(reply: String) -> String {
        var annotating = false
        var ink = ""
        for pair in reply.split(separator: " ") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "annotating": annotating = parts[1] == "true"
            case "ink": ink = String(parts[1])
            default: break
            }
        }
        let text = annotating ? "✎ \(ink)" : "✎"
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {"text":"\(escaped)","class":"\(annotating ? "active" : "idle")","tooltip":"ScribbleEverywhere\\nLeft: annotate\\nRight: colour"}
        """
    }

    private static func sendOrStart(arguments: [String]) -> String {
        let command = arguments.joined(separator: " ")
        let first = send(command: command)
        if !first.hasPrefix("error: daemon") { return first }
        spawnDaemon()
        var last = first
        for _ in 0..<100 {
            usleep(20_000)
            last = send(command: command)
            if !last.hasPrefix("error: daemon") { return last }
        }
        return last
    }

    private static func spawnDaemon() {
        let binary = executablePath()
        let process = Process()
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/setsid") {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/setsid")
            process.arguments = [binary, "daemon"]
        } else {
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["daemon"]
        }
        do {
            let url = URL(fileURLWithPath: LinuxLog.filePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
        } catch {
            fputs("could not start daemon: \(error)\n", stderr)
        }
    }

    private static func executablePath() -> String {
        let raw = CommandLine.arguments[0]
        if raw.hasPrefix("/") { return raw }
        if raw.contains("/") {
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(raw).path
        }
        return Tools.path("scribbleeverywhere") ?? Tools.path("scribbleeverywherectl")
            ?? Tools.path("palimpsest-ink") ?? Tools.path("palimpsestctl") ?? raw
    }

    static func send(command: String) -> String {
        let socketPath = LinuxDaemon.socketPath
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { return "error: socket() failed" }

        var address = unixAddress(path: socketPath)
        let connected = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                connect(fd, sock, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            return "error: daemon not running (connect \(socketPath): \(String(cString: strerror(errno))))"
        }

        // Capture and PNG encoding can take time, but a hung daemon must not
        // leave a Waybar click or shell command waiting forever.
        LinuxSocketIO.setTimeout(5_000, option: SO_SNDTIMEO, fd: fd)
        LinuxSocketIO.setTimeout(30_000, option: SO_RCVTIMEO, fd: fd)
        let sent = LinuxSocketIO.sendAll(Data((command + "\n").utf8), to: fd)
        let reply = sent ? LinuxSocketIO.readLine(from: fd) : nil
        close(fd)
        return reply ?? "error: incomplete daemon response"
    }

    private static let usage = """
    usage:
      scribbleeverywhere daemon             overlay daemon (Hyprland / Wayland)
      scribbleeverywhere version            print the version
      scribbleeverywhere toggle             start annotating, or deliver and stop
      scribbleeverywhere copy               copy the annotated window
      scribbleeverywhere paste              copy and paste into the saved window
      scribbleeverywhere save               save PNG to the annotations folder
      scribbleeverywhere undo | clear       edit strokes while annotating
      scribbleeverywhere colour [index]     cycle, or select a palette colour
      scribbleeverywhere colour-add [hex]   add a colour; hex may be #RRGGBB from hyprpicker
      scribbleeverywhere colour-remove N    remove a palette colour
      scribbleeverywhere colour-name N NAME set or clear a colour name
      scribbleeverywhere colour-replace N HEX
      scribbleeverywhere action [clipboard|copy-and-paste]
      scribbleeverywhere paper-tone [on|off]
      scribbleeverywhere save-annotations [on|off]
      scribbleeverywhere history            count and folder
      scribbleeverywhere history-open [path]
      scribbleeverywhere folder [PATH]      get or set the annotations folder
      scribbleeverywhere autostart [on|off]
      scribbleeverywhere pen-mouse          report Hyprland-managed idle pen behavior
      scribbleeverywhere permissions        grim, wl-copy, wtype, hyprctl, stylus
      scribbleeverywhere paste-target previous|frontmost|pin ADDRESS [name]
      scribbleeverywhere palette-position none|top-left|top-right
      scribbleeverywhere hotkey             documented Hyprland chord (Super+Alt+D)
      scribbleeverywhere menu               JSON for the bar popup
      scribbleeverywhere cancel             stop without copying
      scribbleeverywhere status [--waybar]  daemon state (waybar JSON with --waybar)
      scribbleeverywhere quit               stop the daemon

    Default Hyprland hotkey: Super+Alt+D. colour-add hex may be #RRGGBB from
    hyprpicker (next unused preset if omitted). folder PATH sets the
    annotations folder.
    While annotating: Esc cancels, Ctrl+Z undoes, Ctrl+Backspace clears,
    Ctrl+C copies, Ctrl+Enter pastes. Mouse and touch use a fixed width.
    A tablet pen uses pressure. The right mouse button cycles colour.
    Floating swatches pick colour, clear ink, and save.
    """
}

enum LinuxSelfTest {
    static func run() -> [String] {
        var failures: [String] = []
        var ppm = Data("P6\n2 1\n255\n".utf8)
        ppm.append(contentsOf: [255, 0, 0, 0, 255, 0])
        guard let image = PPMDecoder.decode(ppm), image.width == 2, image.height == 1,
              image[0, 0] == RGBA(r: 255, g: 0, b: 0),
              image[1, 0] == RGBA(r: 0, g: 255, b: 0) else {
            failures.append("PPM decoder did not round-trip a 2x1 image")
            return failures
        }

        let path = FileManager.default.temporaryDirectory.appendingPathComponent("palimpsest-self-test-\(UUID().uuidString).png").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let red = ImageBuffer(width: 1, height: 1, pixels: [255, 0, 0, 255])
        let wrote = red.withRawBytes { pointer in
            palimpsest_write_png_rgba(path, 1, 1, 4, pointer.assumingMemoryBound(to: UInt8.self)) == 0
        }
        let header = (try? Data(contentsOf: URL(fileURLWithPath: path)))?.prefix(8)
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        if !wrote || header.map(Array.init) != pngSignature {
            failures.append("PNG writer did not produce a PNG signature")
        }

        let json = PalimpsestLinuxApp.waybarJSON(reply: "annotating=true strokes=1 ink=#FF3B30FF")
        if !json.contains("\"class\":\"active\"") || !json.contains("#FF3B30FF") {
            failures.append("waybar JSON missing active state: \(json)")
        }

        var overlay = palimpsest_output_info()
        overlay.logical_width = 800
        overlay.logical_height = 600
        overlay.buffer_width = 800
        overlay.buffer_height = 600
        overlay.scale = 1
        let palette = Palette.standard
        if LinuxColourNames.unusedExtras(in: palette).isEmpty {
            failures.append("unusedExtras empty for Palette.standard")
        }
        if LinuxPaletteHUD.make(palette: palette, overlay: overlay, position: .none) != nil {
            failures.append("HUD none should hide the capsule")
        }
        guard let hud = LinuxPaletteHUD.make(palette: palette, overlay: overlay, position: .topRight) else {
            failures.append("HUD top-right missing")
            return failures
        }
        if hud.hit(Point(x: hud.swatches[0].midX, y: hud.swatches[0].midY)) != .select(0) {
            failures.append("HUD missed the first swatch")
        }
        if hud.hit(Point(x: hud.clear.midX, y: hud.clear.midY)) != .clear {
            failures.append("HUD missed the clear control")
        }
        if hud.hit(Point(x: hud.save.midX, y: hud.save.midY)) != .save {
            failures.append("HUD missed the save control")
        }
        if hud.hit(Point(x: 10, y: 10)) != nil {
            failures.append("HUD hit outside the capsule")
        }
        return failures
    }
}

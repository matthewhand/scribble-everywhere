import Foundation
import PalimpsestCore
import CPalimpsestLinux

/// PNG annotation archive, matching macOS `AnnotationHistory` without AppKit.
struct LinuxHistory {
    var folder: String

    static var defaultFolder: String {
        let base = env("XDG_DATA_HOME") ?? "\(env("HOME") ?? ".")/.local/share"
        return "\(base)/palimpsest-ink/annotations"
    }

    struct Entry {
        var path: String
        var name: String
        var modified: Date
    }

    func save(_ image: ImageBuffer, at date: Date = Date()) -> String? {
        do {
            try FileManager.default.createDirectory(
                atPath: folder,
                withIntermediateDirectories: true
            )
        } catch {
            LinuxLog.log("Could not create annotations folder: \(error)")
            return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
        let path = "\(folder)/Annotation \(stamp) \(UUID().uuidString).png"
        let wrote = image.withRawBytes { pointer in
            palimpsest_write_png_rgba(
                path,
                Int32(image.width),
                Int32(image.height),
                Int32(image.width * 4),
                pointer.assumingMemoryBound(to: UInt8.self)
            ) == 0
        }
        guard wrote else {
            LinuxLog.log("Could not write annotation PNG \(path)")
            return nil
        }
        return path
    }

    func files() -> [Entry] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: folder),
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { url -> Entry? in
            guard url.pathExtension.lowercased() == "png" else { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return Entry(path: url.path, name: url.deletingPathExtension().lastPathComponent, modified: modified)
        }
        .sorted { $0.modified > $1.modified }
    }

    @discardableResult
    func reveal(_ path: String? = nil) -> Bool {
        let target = path ?? folder
        guard FileManager.default.fileExists(atPath: target) || path == nil else { return false }
        if path == nil {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        guard let opener = Tools.path("xdg-open") ?? Tools.path("gio") else {
            LinuxLog.log("xdg-open is not installed")
            return false
        }
        let args = opener.hasSuffix("/gio") ? ["open", target] : [target]
        return Shell.run(opener, arguments: args).status == 0
    }
}

enum LinuxAutostart {
    static func desktopPath() -> String {
        let base = env("XDG_CONFIG_HOME") ?? "\(env("HOME") ?? ".")/.config"
        return "\(base)/autostart/palimpsest-ink.desktop"
    }

    static func isEnabled() -> Bool {
        FileManager.default.fileExists(atPath: desktopPath())
    }

    static func setEnabled(_ enabled: Bool, at path: String = desktopPath(), binary: String? = nil) -> Bool {
        if !enabled {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &directory) else { return true }
            guard !directory.boolValue else { return false }
            do { try FileManager.default.removeItem(atPath: path); return true }
            catch { LinuxLog.log("Autostart removal failed: \(error)"); return false }
        }
        let binary = binary ?? Tools.path("scribbleeverywhere") ?? Tools.path("palimpsest-ink")
            ?? "\(env("HOME") ?? ".")/.local/bin/scribbleeverywhere"
        guard let body = desktopEntry(binary: binary) else { return false }
        do {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try body.write(toFile: path, atomically: true, encoding: .utf8)
            return true
        } catch {
            LinuxLog.log("Autostart write failed: \(error)")
            return false
        }
    }

    static func desktopEntry(binary: String) -> String? {
        guard !binary.contains("="), !binary.contains("\n"), !binary.contains("\r"), !binary.contains("\0") else { return nil }
        // Desktop Entry string escaping happens before Exec argument quoting.
        let quoted = binary.replacingOccurrences(of: "\\", with: "\\\\\\\\")
            .replacingOccurrences(of: "\"", with: "\\\\\"")
            .replacingOccurrences(of: "`", with: "\\\\`")
            .replacingOccurrences(of: "$", with: "\\\\$")
            .replacingOccurrences(of: "%", with: "%%")
        let body = """
        [Desktop Entry]
        Type=Application
        Name=ScribbleEverywhere
        Comment=Annotate the focused window
        Exec="\(quoted)" daemon
        Icon=applications-graphics
        Terminal=false
        X-GNOME-Autostart-enabled=true
        """
        return body
    }
}

import Foundation
import Glibc

/// Reads BTN_STYLUS from the kernel event node so the barrel can start
/// annotation while the overlay is unmapped. Wayland tablet-v2 only delivers
/// that button to a focused surface, which we do not have until we are already
/// annotating.
final class StylusEvdevMonitor {
    private(set) var fd: Int32 = -1
    private var lastRetry = Date.distantPast
    private var loggedDenied = false
    private var openedPath: String?

    func close() {
        if fd >= 0 {
            _ = Glibc.close(fd)
            fd = -1
        }
        openedPath = nil
    }

    func openIfNeeded(force: Bool = false) {
        if fd >= 0 { return }
        let now = Date()
        if !force, now.timeIntervalSince(lastRetry) < 2 { return }
        lastRetry = now

        let devices = Self.discover()
        if devices.isEmpty { return }

        var denied: [String] = []
        for device in devices {
            let opened = device.path.withCString { Glibc.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC) }
            if opened >= 0 {
                fd = opened
                openedPath = device.path
                LinuxLog.log("Stylus evdev \(device.path) (\(device.name))")
                loggedDenied = false
                return
            }
            let err = errno
            if err == EACCES || err == EPERM {
                denied.append(device.path)
            } else if !loggedDenied {
                LinuxLog.log(
                    "Stylus evdev \(device.path) open failed: \(String(cString: strerror(err)))"
                )
            }
        }
        if !denied.isEmpty, !loggedDenied {
            loggedDenied = true
            LinuxLog.log(
                "Barrel start needs read access to \(denied.joined(separator: ", ")). "
                    + "Install packaging/linux/69-palimpsest-ink-stylus.rules "
                    + "(scripts/install-linux-stylus-access.sh)."
            )
        }
    }

    /// True if BTN_STYLUS (0x14B) was pressed since the last call.
    /// BTN_STYLUS2 (0x14C) is drained but ignored so barrel 2 cannot start
    /// annotation while the overlay is hidden.
    func consumePress() -> Bool {
        guard fd >= 0 else { return false }
        var pressed = false
        var bytes = [UInt8](repeating: 0, count: 24 * 64)
        while true {
            let count = bytes.withUnsafeMutableBytes { raw -> ssize_t in
                Glibc.read(fd, raw.baseAddress, raw.count)
            }
            if count == 0 {
                LinuxLog.log("Stylus evdev closed (\(openedPath ?? "?"))")
                close()
                break
            }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                    break
                }
                LinuxLog.log("Stylus evdev read failed: \(String(cString: strerror(errno)))")
                close()
                break
            }
            var offset = 0
            while offset + 24 <= Int(count) {
                let type = Self.u16(bytes, offset + 16)
                let code = Self.u16(bytes, offset + 18)
                let value = Self.i32(bytes, offset + 20)
                if type == 1 && value == 1 && (code == 0x14B || code == 0x14C) {
                    LinuxLog.log(String(format: "evdev stylus button code=0x%X", code))
                    if code == 0x14B {
                        pressed = true
                    }
                }
                offset += 24
            }
            if count < bytes.count { break }
        }
        return pressed
    }

    private struct Device {
        var name: String
        var path: String
    }

    private static func discover() -> [Device] {
        // /proc files report size 0, so String(contentsOfFile:) returns empty.
        guard let text = readProcDevices() else { return [] }
        var devices: [Device] = []
        var name = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("N: Name=") {
                name = String(line.dropFirst("N: Name=".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if line.hasPrefix("H: Handlers=") {
                guard isStylusName(name) else { continue }
                let handlers = line.dropFirst("H: Handlers=".count)
                for token in handlers.split(separator: " ") where token.hasPrefix("event") {
                    devices.append(Device(name: name, path: "/dev/input/\(token)"))
                }
            }
        }
        return devices
    }

    private static func readProcDevices() -> String? {
        let fd = Glibc.open("/proc/bus/input/devices", O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { _ = Glibc.close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> ssize_t in
                Glibc.read(fd, raw.baseAddress, raw.count)
            }
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(Int(count)))
        }
        return String(data: data, encoding: .utf8)
    }

    private static func isStylusName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.contains("touchscreen") || lower.contains("touchpad") { return false }
        return lower.contains("stylus") || lower.contains("iptsd virtual stylus")
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func i32(_ bytes: [UInt8], _ offset: Int) -> Int32 {
        Int32(
            bitPattern: UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
        )
    }
}

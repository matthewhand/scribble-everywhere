import Foundation
import Glibc
import PalimpsestCore
import CPalimpsestLinux

/// Runs an external tool (grim, wl-copy, wtype, hyprctl) and returns stdout.
enum Shell {
    @discardableResult
    static func run(_ command: String, arguments: [String], timeout: TimeInterval = 3) -> (status: Int32, stdout: Data, stderr: Data) {
        let strings = ([command] + arguments).map { strdup($0) }
        defer { for string in strings { free(string) } }
        guard strings.allSatisfy({ $0 != nil }) else { return (-1, Data(), Data()) }
        var argv = strings + [nil]
        var pid: Int32 = 0, outFD: Int32 = -1, errFD: Int32 = -1
        let launched = argv.withUnsafeMutableBufferPointer {
            palimpsest_process_spawn(command, $0.baseAddress, &pid, &outFD, &errFD)
        }
        guard launched == 0 else {
            LinuxLog.log("Could not run \(command)")
            return (-1, Data(), Data())
        }
        defer { close(outFD); close(errFD) }
        // Drain both pipes without blocking. A child that hangs, or a
        // grandchild that inherits a pipe, must not freeze the overlay.
        var descriptors = [pollfd(fd: outFD, events: Int16(POLLIN), revents: 0),
                           pollfd(fd: errFD, events: Int16(POLLIN), revents: 0)]
        var output = [Data(), Data()]
        var readFailed = false
        var reaped = false
        var status: Int32 = -1
        var buffer = [UInt8](repeating: 0, count: 16384)
        let deadline = ProcessInfo.processInfo.systemUptime + max(timeout, 0)
        while !reaped || descriptors.contains(where: { $0.fd >= 0 }) {
            if !reaped {
                let state = palimpsest_process_poll(pid, &status)
                if state < 0 {
                    palimpsest_process_terminate(pid, 0)
                    return (-1, Data(), Data())
                }
                reaped = state == 1
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                palimpsest_process_terminate(pid, reaped ? 0 : 1)
                LinuxLog.log("\(command) timed out")
                return (-1, Data(), Data())
            }
            let descriptorCount = nfds_t(descriptors.count)
            _ = poll(&descriptors, descriptorCount, 20)
            for index in descriptors.indices where descriptors[index].fd >= 0 && descriptors[index].revents != 0 {
                // Bound each turn so a noisy child cannot starve the other
                // pipe or prevent the deadline from being checked.
                for _ in 0..<16 {
                    let count = Glibc.read(descriptors[index].fd, &buffer, buffer.count)
                    if count > 0 {
                        output[index].append(contentsOf: buffer.prefix(count))
                    } else if count == 0 {
                        descriptors[index].fd = -1
                        break
                    } else if errno == EINTR {
                        continue
                    } else if errno == EAGAIN || errno == EWOULDBLOCK {
                        break
                    } else {
                        readFailed = true
                        descriptors[index].fd = -1
                        break
                    }
                }
            }
        }
        return (readFailed ? -1 : status, output[0], output[1])
    }

    static func hyprctl(_ args: String...) -> Data {
        guard let tool = Tools.path("hyprctl") else { return Data() }
        return run(tool, arguments: Array(args)).stdout
    }

    static func hasTool(_ command: String) -> Bool {
        run("/usr/bin/which", arguments: [command]).status == 0
    }
}

/// The focused Hyprland window: address, geometry and class, parsed from
/// `hyprctl -j activewindow`.
struct HyprlandWindow {
    var address: String?
    var frame: Rect
    var className: String?
    var title: String?
    var mapped: Bool = true

    var displayName: String {
        if let title, !title.isEmpty { return title }
        if let className, !className.isEmpty { return className }
        return address ?? "Window"
    }

    static func active() -> HyprlandWindow? {
        let json = Shell.hyprctl("-j", "activewindow")
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            return nil
        }
        return parse(object)
    }

    static func client(address: String) -> HyprlandWindow? {
        all().first { $0.address == address }
    }

    static func all() -> [HyprlandWindow] {
        let json = Shell.hyprctl("-j", "clients")
        guard let list = try? JSONSerialization.jsonObject(with: json) as? [Any] else { return [] }
        return list.compactMap { entry in
            guard let object = entry as? [String: Any] else { return nil }
            let window = parse(object)
            guard window.mapped, window.address?.isEmpty == false else { return nil }
            return window
        }
    }

    private static func parse(_ object: [String: Any]) -> HyprlandWindow {
        var frame = Rect(x: 0, y: 0, width: 0, height: 0)
        if let at = object["at"] as? [Any], at.count == 2,
           let size = object["size"] as? [Any], size.count == 2,
           let x = JSONNumber.double(at[0]), let y = JSONNumber.double(at[1]),
           let width = JSONNumber.double(size[0]), let height = JSONNumber.double(size[1]) {
            frame = Rect(x: x, y: y, width: width, height: height)
        }
        let mapped: Bool
        if let flag = object["mapped"] as? Bool {
            mapped = flag
        } else {
            mapped = true
        }
        return HyprlandWindow(
            address: object["address"] as? String,
            frame: frame,
            className: object["class"] as? String,
            title: object["title"] as? String,
            mapped: mapped
        )
    }
}

/// PPM (P6) decoder for `grim -t ppm` output - Foundation-only.
enum PPMDecoder {
    static func decode(_ data: Data) -> ImageBuffer? {
        var index = 0
        var magic = ""
        var width = 0
        var height = 0

        func token() -> String? {
            // Skip whitespace and '#' comments.
            while index < data.count {
                let byte = data[index]
                if byte == UInt8(ascii: "#") {
                    while index < data.count, data[index] != UInt8(ascii: "\n") { index += 1 }
                } else if byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\n")
                    || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\r") {
                    index += 1
                } else {
                    break
                }
            }
            var value = ""
            while index < data.count {
                let byte = data[index]
                if byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\n")
                    || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\r") {
                    break
                }
                value.append(Character(UnicodeScalar(byte)))
                index += 1
            }
            return value.isEmpty ? nil : value
        }

        guard let magicToken = token(), magicToken == "P6" else { return nil }
        guard let widthToken = token(), let widthValue = Int(widthToken) else { return nil }
        guard let heightToken = token(), let heightValue = Int(heightToken) else { return nil }
        guard let maxvalToken = token(), let maxval = Int(maxvalToken), maxval == 255 else { return nil }

        magic = magicToken
        width = widthValue
        height = heightValue
        _ = magic

        // Exactly one whitespace byte separates maxval from the raster.
        guard index < data.count else { return nil }
        if data[index] == 13, index + 1 < data.count, data[index + 1] == 10 { index += 2 }
        else { index += 1 }

        // Check against the supplied payload before multiplying dimensions.
        // Malformed/negative headers must not overflow or allocate huge buffers.
        guard width > 0, height > 0, width <= (data.count - index) / 3,
              height <= (data.count - index) / (width * 3) else { return nil }
        let rasterCount = width * height * 3
        guard rasterCount <= data.count - index, width * height <= Int.max / 4 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for pixel in 0..<(width * height) {
            let source = index + pixel * 3
            let destination = pixel * 4
            pixels[destination] = data[source]
            pixels[destination + 1] = data[source + 1]
            pixels[destination + 2] = data[source + 2]
            pixels[destination + 3] = 255
        }
        return ImageBuffer(width: width, height: height, pixels: pixels)
    }
}

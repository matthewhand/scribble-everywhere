import Foundation
import WinSDK
import PalimpsestCore

/// File logging for the Windows shell (no unified logging there).
/// Written to %LOCALAPPDATA%\PalimpsestInk\log.txt.
enum WinLog {
    static func log(_ message: String) {
        let dir = logDirectory()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let line = "\(timestamp()) \(message)\n"
        let path = "\(dir)\\log.txt"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: path),
           let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    static func logDirectory() -> String {
        let base = env("LOCALAPPDATA") ?? env("APPDATA") ?? "."
        return "\(base)\\PalimpsestInk"
    }

    static func appDataDirectory() -> String {
        let base = env("APPDATA") ?? env("LOCALAPPDATA") ?? "."
        return "\(base)\\PalimpsestInk"
    }

    private static func env(_ name: String) -> String? {
        var buffer = [WCHAR](repeating: 0, count: 1024)
        let count = GetEnvironmentVariableW(name.wide, &buffer, UInt32(buffer.count))
        guard count > 0, count < UInt32(buffer.count) else { return nil }
        return String(decoding: buffer.prefix(Int(count)).map { UInt16($0) }, as: UTF16.self)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }
}

extension String {
    /// NUL-terminated UTF-16 for `LPCWSTR` parameters.
    var wide: [WCHAR] {
        var units = Array(utf16)
        units.append(0)
        return units
    }
}

extension Array where Element == WCHAR {
    /// Interprets the buffer as a NUL-terminated string.
    var string: String {
        let end = firstIndex(of: 0) ?? count
        return String(decoding: prefix(end).map { UInt16($0) }, as: UTF16.self)
    }
}

/// Win32 `LOWORD`/`HIWORD` macros for mouse-coordinate lParams.
func LOWORD(_ value: LPARAM) -> Int32 { Int32(Int(value) & 0xFFFF) }
func HIWORD(_ value: LPARAM) -> Int32 { Int32((Int(value) >> 16) & 0xFFFF) }

/// RGBA (core) -> COLORREF (0x00BBGGRR, opaque).
func makeColorref(_ color: RGBA) -> COLORREF {
    let red = UInt32(color.r)
    let green = UInt32(color.g) << 8
    let blue = UInt32(color.b) << 16
    return COLORREF(red | green | blue)
}

/// Copies a Swift string's UTF-16 bytes (with NUL) into a Win32 fixed WCHAR
/// field. WinSDK models those fields as tuples, which cannot use
/// `withUnsafeMutableBytes`, so this takes the address of the field.
func copyIntoFixedField<W>(_ field: inout W, _ text: [WCHAR]) {
    withUnsafeMutablePointer(to: &field) { destination in
        text.withUnsafeBytes { source in
            let capacity = MemoryLayout<W>.size
            memcpy(destination, source.baseAddress, min(source.count, capacity))
        }
    }
}
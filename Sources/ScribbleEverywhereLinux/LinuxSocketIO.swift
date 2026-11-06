import Foundation
import Glibc

/// Unix stream sockets can split both writes and UTF-8 characters arbitrarily.
enum LinuxSocketIO {
    @discardableResult
    static func setTimeout(_ milliseconds: Int, option: Int32, fd: Int32) -> Bool {
        var timeout = timeval(tv_sec: milliseconds / 1000, tv_usec: (milliseconds % 1000) * 1000)
        return setsockopt(fd, SOL_SOCKET, option, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0
    }

    static func sendAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                let count = Glibc.send(fd, base.advanced(by: offset), bytes.count - offset, Int32(MSG_NOSIGNAL))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }

    /// Read one complete line before decoding, so a multi-byte character split
    /// across recv calls is not replaced by the Unicode replacement character.
    static func readLine(from fd: Int32, maxBytes: Int = 16 * 1024 * 1024) -> String? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= maxBytes {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            data.append(contentsOf: buffer.prefix(count))
            if let newline = data.firstIndex(of: 10) {
                guard newline <= maxBytes else { return nil }
                return String(data: data.prefix(upTo: newline), encoding: .utf8)
            }
        }
        return nil
    }
}

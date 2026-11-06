import Foundation
import WinSDK
import PalimpsestCore

/// Clipboard (registered PNG format plus CF_DIBV5) and paste (SendInput Ctrl+V).
/// PNG bytes come from `ImageBuffer.pngData()` in this file. Core has no PNG
/// writer, and GDI+ is not linked.
final class WinClipboard: ClipboardWriter {
    /// EmptyClipboard requires an actual owning window before SetClipboardData.
    var owner: HWND?

    func write(image: ImageBuffer, png: Data?) {
        _ = writeNow(image: image, png: png)
    }

    /// The Windows controller needs a result so it can retain ink on failure
    /// and avoid pasting stale clipboard contents.
    func writeNow(image: ImageBuffer, png: Data?) -> Bool {
        guard let owner, OpenClipboard(owner) else {
            WinLog.log("OpenClipboard failed")
            return false
        }
        defer { CloseClipboard() }
        guard EmptyClipboard() else {
            WinLog.log("EmptyClipboard failed")
            return false
        }

        // PNG for Edge and Word. CF_DIB for Paint, RichEdit, and most Win32
        // apps. CF_DIBV5 alone is not enough: those apps never ask for it.
        var placedPng = false
        if let png {
            let format = RegisterClipboardFormatW("PNG".wide)
            placedPng = putOnClipboard(format: UINT(format), bytes: png)
        }
        let placedDib = putClassicDib(image)
        let placedV5 = putDib(image)
        WinLog.log("clipboard png=\(placedPng) dib=\(placedDib) dibv5=\(placedV5) bytes=\(png?.count ?? 0)")
        return placedPng || placedDib || placedV5
    }

    private func putOnClipboard(format: UINT, bytes: Data) -> Bool {
        let handle = GlobalAlloc(UINT(GMEM_MOVEABLE), SIZE_T(bytes.count))
        guard let handle else { return false }
        guard let target = GlobalLock(handle) else {
            GlobalFree(handle)
            return false
        }
        do {
            _ = bytes.withUnsafeBytes { raw in
                memcpy(target, raw.baseAddress, bytes.count)
            }
            GlobalUnlock(handle)
        }
        if SetClipboardData(format, handle) == nil {
            GlobalFree(handle)
            return false
        }
        return true
    }

    /// Bottom-up 32-bit BI_RGB. This is the format `CF_DIB` readers expect.
    private func putClassicDib(_ image: ImageBuffer) -> Bool {
        var header = BITMAPINFOHEADER()
        header.biSize = UINT32(MemoryLayout<BITMAPINFOHEADER>.size)
        header.biWidth = Int32(image.width)
        header.biHeight = Int32(image.height)
        header.biPlanes = 1
        header.biBitCount = 32
        header.biCompression = UInt32(BI_RGB)
        header.biSizeImage = UINT32(image.width * image.height * 4)

        let rgba = image.data()
        let stride = image.width * 4
        var bgra = [UInt8](repeating: 0, count: rgba.count)
        var y = 0
        while y < image.height {
            let src = y * stride
            let dst = (image.height - 1 - y) * stride
            var x = 0
            while x < stride {
                bgra[dst + x] = rgba[src + x + 2]
                bgra[dst + x + 1] = rgba[src + x + 1]
                bgra[dst + x + 2] = rgba[src + x]
                bgra[dst + x + 3] = 255
                x += 4
            }
            y += 1
        }
        return putBitmap(header: header, pixels: bgra, format: UINT(CF_DIB))
    }

    private func putDib(_ image: ImageBuffer) -> Bool {
        var header = BITMAPV5HEADER()
        header.bV5Size = UINT32(MemoryLayout<BITMAPV5HEADER>.size)
        header.bV5Width = Int32(image.width)
        header.bV5Height = -Int32(image.height) // top-down
        header.bV5Planes = 1
        header.bV5BitCount = 32
        header.bV5Compression = UInt32(BI_BITFIELDS)
        // Little-endian memory order is B,G,R,A. ImageBuffer is R,G,B,A.
        header.bV5RedMask = 0x00FF0000
        header.bV5GreenMask = 0x0000FF00
        header.bV5BlueMask = 0x000000FF
        header.bV5AlphaMask = 0xFF000000

        let rgba = image.data()
        var bgra = [UInt8](repeating: 0, count: rgba.count)
        var index = 0
        while index + 3 < rgba.count {
            bgra[index] = rgba[index + 2]
            bgra[index + 1] = rgba[index + 1]
            bgra[index + 2] = rgba[index]
            bgra[index + 3] = rgba[index + 3]
            index += 4
        }

        return putBitmap(header: header, pixels: bgra, format: UINT(CF_DIBV5))
    }

    private func putBitmap<Header>(header: Header, pixels: [UInt8], format: UINT) -> Bool {
        let headerSize = MemoryLayout<Header>.size
        let total = headerSize + pixels.count
        let handle = GlobalAlloc(UINT(GMEM_MOVEABLE), SIZE_T(total))
        guard let handle else { return false }
        guard let target = GlobalLock(handle) else {
            GlobalFree(handle)
            return false
        }
        do {
            var header = header
            _ = withUnsafeMutableBytes(of: &header) { headerBytes in
                memcpy(target, headerBytes.baseAddress, headerSize)
            }
            _ = pixels.withUnsafeBytes { raw in
                memcpy(target.advanced(by: headerSize), raw.baseAddress, pixels.count)
            }
            GlobalUnlock(handle)
        }
        if SetClipboardData(format, handle) == nil {
            GlobalFree(handle)
            return false
        }
        return true
    }
}

extension ImageBuffer {
    /// Uncompressed RGBA8 PNG. The macOS shell encodes via CGImage; Core does not.
    func pngData() -> Data {
        PngWriter.encode(rgba: [UInt8](data()), width: width, height: height)
    }
}

/// Minimal PNG encoder: filter-none rows inside zlib stored blocks.
enum PngWriter {
    static func encode(rgba: [UInt8], width: Int, height: Int) -> Data {
        let rowBytes = width * 4
        var raw = [UInt8]()
        raw.reserveCapacity(height * (1 + rowBytes))
        for row in 0..<height {
            raw.append(0)
            let start = row * rowBytes
            raw.append(contentsOf: rgba[start..<(start + rowBytes)])
        }

        var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
        var ihdr = Data()
        appendBE(&ihdr, UInt32(width))
        appendBE(&ihdr, UInt32(height))
        ihdr.append(contentsOf: [8, 6, 0, 0, 0])
        png.append(chunk(type: [73, 72, 68, 82], payload: ihdr))
        png.append(chunk(type: [73, 68, 65, 84], payload: zlibStore(raw)))
        png.append(chunk(type: [73, 69, 78, 68], payload: Data()))
        return png
    }

    private static func zlibStore(_ data: [UInt8]) -> Data {
        // CMF/FLG 0x78 0x01: 32 KiB window, no preset dictionary, check bits pass.
        var out = Data([0x78, 0x01])
        var offset = 0
        repeat {
            let remaining = data.count - offset
            let size = min(remaining, 65535)
            let last = offset + size >= data.count
            out.append(last ? 1 : 0)
            let len = UInt16(size)
            let nlen = ~len
            out.append(UInt8(len & 0xFF))
            out.append(UInt8(len >> 8))
            out.append(UInt8(nlen & 0xFF))
            out.append(UInt8(nlen >> 8))
            if size > 0 {
                out.append(contentsOf: data[offset..<(offset + size)])
            }
            offset += size
        } while offset < data.count

        appendBE(&out, adler32(data))
        return out
    }

    private static func adler32(_ data: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }

    private static func chunk(type: [UInt8], payload: Data) -> Data {
        var crcInput = type
        crcInput.append(contentsOf: payload)
        var out = Data()
        appendBE(&out, UInt32(payload.count))
        out.append(contentsOf: type)
        out.append(payload)
        appendBE(&out, crc32(crcInput))
        return out
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var c = UInt32(index)
        for _ in 0..<8 {
            if (c & 1) == 1 {
                c = 0xEDB88320 ^ (c >> 1)
            } else {
                c >>= 1
            }
        }
        return c
    }

    private static func crc32(_ data: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for byte in data {
            let index = Int((c ^ UInt32(byte)) & 0xFF)
            c = crcTable[index] ^ (c >> 8)
        }
        return c ^ 0xFFFFFFFF
    }

    private static func appendBE(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}

/// Reactivates a window and sends Ctrl+V via SendInput.
final class WinPaster: Paster {
    func paste(into applicationID: String?) async -> Bool {
        return pasteNow()
    }

    func pasteNow(alt: Bool = false, destination: HWND? = nil, expected: WinWindowTargeting.Identity? = nil) -> Bool {
        // The barrel-button listener owns a low-level keyboard hook on this
        // thread. SendInput delivers each key by sending that hook a message.
        // Calling it here deadlocks until Windows drops the key, and the call
        // still returns success. Inject from another thread and keep pumping
        // so the hook can run.
        let gate = PasteGate()
        let destinationBits = destination.map { UInt(bitPattern: Int(bitPattern: $0)) }
        let thread = Thread {
            // Check focus and pinned-window identity on the injecting thread,
            // after scheduling it, immediately before emitting input.
            if let destinationBits {
                guard let destination = HWND(bitPattern: Int(bitPattern: destinationBits)) else { gate.finish(false); return }
                guard GetForegroundWindow() == destination else { gate.finish(false); return }
                if let expected, !WinWindowTargeting.identityMatches(expected: expected, observed: WinWindowTargeting.identity(of: destination)) {
                    gate.finish(false)
                    return
                }
            }
            gate.finish(WinPaster.injectChord(alt: alt))
        }
        thread.start()
        let deadline = Date().addingTimeInterval(1.5)
        var state = gate.poll()
        while !state.done && Date() < deadline {
            WinPaster.pumpOnce()
            if !state.done {
                Thread.sleep(forTimeInterval: 0.005)
            }
            state = gate.poll()
        }
        WinLog.log("SendInput \(alt ? "alt+v" : "ctrl+v") pasted=\(state.ok) done=\(state.done)")
        return state.ok && state.done
    }

    /// Lets `SetForegroundWindow` succeed when this process is not the
    /// foreground. An Alt tap is enough; do not call `AttachThreadInput`.
    static func pulseAlt() {
        let thread = Thread {
            let scan = BYTE(MapVirtualKeyW(UINT(VK_MENU), 0))
            keybd_event(BYTE(VK_MENU), scan, 0, 0)
            keybd_event(BYTE(VK_MENU), scan, DWORD(KEYEVENTF_KEYUP), 0)
        }
        thread.start()
        pump(for: 0.08)
    }

    static func pump(for interval: TimeInterval) {
        let deadline = Date().addingTimeInterval(interval)
        while Date() < deadline {
            pumpOnce()
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    static func pumpOnce() {
        var message = MSG()
        let remove = UINT(1) // PM_REMOVE
        while PeekMessageW(&message, nil, 0, 0, remove) {
            let id = UINT(message.message)
            if id == UINT(WM_QUIT) {
                // DispatchMessage does not deliver WM_QUIT. Preserve it for the
                // application's outer GetMessage loop instead of eating Quit.
                PostQuitMessage(Int32(truncatingIfNeeded: message.wParam))
                return
            }
            // A pen click or tray command mid-paste would re-enter capture.
            if id == UINT(WM_HOTKEY) || id == WinController.WM_APP_SHOW_MENU || id == UINT(WM_COMMAND) {
                continue
            }
            _ = TranslateMessage(&message)
            _ = DispatchMessageW(&message)
        }
    }

    private static func injectChord(alt: Bool) -> Bool {
        var inputs = [INPUT](repeating: INPUT(), count: 4)
        func fill(_ index: Int, _ vk: UInt16, _ up: Bool) {
            var key = KEYBDINPUT()
            key.wVk = vk
            key.wScan = WORD(MapVirtualKeyW(UINT(vk), 0))
            key.dwFlags = DWORD(up ? KEYEVENTF_KEYUP : 0)
            inputs[index].type = DWORD(INPUT_KEYBOARD)
            inputs[index].ki = key
        }
        // Windows Terminal eats Ctrl+V and drops an image clipboard. Grok
        // reads that image on Alt+V.
        let modifier = UInt16(alt ? VK_MENU : VK_CONTROL)
        fill(0, modifier, false)
        fill(1, 0x56, false)
        fill(2, 0x56, true)
        fill(3, modifier, true)
        let sent = SendInput(UINT(inputs.count), &inputs, Int32(MemoryLayout<INPUT>.size))
        return sent == inputs.count
    }
}

/// Cross-thread result of `SendInput`. The hook thread only reads it.
private final class PasteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var ok = false

    func finish(_ value: Bool) {
        lock.lock()
        ok = value
        done = true
        lock.unlock()
    }

    func poll() -> (done: Bool, ok: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (done, ok)
    }
}

/// Finds the foreground (previous/frontmost) window, mirroring WindowTargeting.
enum WinWindowTargeting {
    /// An HWND and PID may be recycled; pair them with process creation time
    /// and the window's class and title. Title changes require re-selection.
    struct Identity: Codable, Equatable, Sendable {
        var processId: UInt32
        var processCreation: UInt64
        var className: String
        var title: String
    }

    struct Target {
        var hwnd: HWND
        var frame: Rect
        var processName: String?
    }

    /// One visible top-level window the tray menu can pin as the paste target.
    struct ListedWindow {
        var hwnd: HWND
        var title: String
        var processName: String
        var identity: Identity

        func label(duplicate: Bool) -> String {
            let name = duplicate ? "\(title) — \(processName)" : title
            // The owner-draw menu uses DT_NOPREFIX, so ampersands are literal.
            if name.count <= 70 { return name }
            return String(name.prefix(67)) + "..."
        }
    }

    static func bits(_ hwnd: HWND) -> String {
        String(UInt(bitPattern: Int(bitPattern: hwnd)))
    }

    static func label(for hwnd: HWND?) -> String {
        guard let hwnd else { return "none" }
        let name = window(hwnd)?.processName ?? "window"
        return "\(name) \(bits(hwnd))"
    }

    /// Windows Terminal handles Ctrl+V itself and pastes only text, so an
    /// image clipboard never reaches Grok. Alt+V is the chord Grok listens for.
    static func prefersAltImagePaste(_ hwnd: HWND) -> Bool {
        let process = window(hwnd)?.processName?.lowercased() ?? ""
        if process == "windowsterminal.exe" { return true }
        var buffer = [WCHAR](repeating: 0, count: 256)
        let count = GetClassNameW(hwnd, &buffer, Int32(buffer.count))
        guard count > 0 else { return false }
        let name = buffer.prefix(Int(count)).map { UInt16($0) }.string
        return name == "CASCADIA_HOSTING_WINDOW_CLASS"
    }

    static func hwnd(from bits: String) -> HWND? {
        guard let value = UInt(bits) else { return nil }
        return HWND(bitPattern: Int(bitPattern: value))
    }

    static func foregroundWindow() -> Target? {
        guard let hwnd = GetForegroundWindow() else { return nil }
        return window(hwnd)
    }

    /// A foreground window may belong to our settings, tray, or overlay.
    /// Those windows cannot be the user's underlying capture/paste target.
    static func externalWindow(_ hwnd: HWND?) -> HWND? {
        guard let hwnd, IsWindow(hwnd) else { return nil }
        var processId: DWORD = 0
        _ = GetWindowThreadProcessId(hwnd, &processId)
        guard processId != 0, processId != GetCurrentProcessId() else { return nil }
        return hwnd
    }

    static func identity(of hwnd: HWND) -> Identity? {
        guard externalWindow(hwnd) != nil else { return nil }
        var pid: DWORD = 0
        _ = GetWindowThreadProcessId(hwnd, &pid)
        guard let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, pid) else { return nil }
        defer { CloseHandle(process) }
        var creation = FILETIME(), exit = FILETIME(), kernel = FILETIME(), user = FILETIME()
        guard GetProcessTimes(process, &creation, &exit, &kernel, &user) else { return nil }
        let created = UInt64(creation.dwHighDateTime) << 32 | UInt64(creation.dwLowDateTime)
        var classBuffer = [WCHAR](repeating: 0, count: 256)
        let classLength = GetClassNameW(hwnd, &classBuffer, Int32(classBuffer.count))
        guard classLength > 0 else { return nil }
        let titleLength = GetWindowTextLengthW(hwnd)
        guard titleLength > 0, titleLength < 32768 else { return nil }
        var titleBuffer = [WCHAR](repeating: 0, count: Int(titleLength) + 1)
        guard GetWindowTextW(hwnd, &titleBuffer, Int32(titleBuffer.count)) > 0 else { return nil }
        var finalPid: DWORD = 0
        guard GetWindowThreadProcessId(hwnd, &finalPid) != 0, finalPid == pid else { return nil }
        return Identity(processId: pid, processCreation: created, className: classBuffer.string, title: titleBuffer.string)
    }

    static func pinnedWindow(bits: String?, expected: Identity?) -> HWND? {
        guard let bits, let expected, let hwnd = hwnd(from: bits),
              IsWindowVisible(hwnd), identityMatches(expected: expected, observed: identity(of: hwnd)) else { return nil }
        return hwnd
    }

    /// Resolve only the window remembered at annotation start. Once it is
    /// gone or changes identity, another foreground window is not a substitute.
    static func rememberedCaptureTarget(_ hwnd: HWND?, expected: Identity?) -> Target? {
        guard let hwnd, let validated = pinnedWindow(bits: bits(hwnd), expected: expected) else { return nil }
        return window(validated)
    }

    static func identityMatches(expected: Identity?, observed: Identity?) -> Bool {
        guard let expected, let observed else { return false }
        return expected == observed
    }

    /// Topmost visible window that is not this process. Used when the paste
    /// preference is the frontmost window, after the overlay has been hidden.
    static func frontmostOther() -> HWND? {
        var found: HWND?
        withUnsafeMutablePointer(to: &found) { pointer in
            _ = EnumWindows({ hwnd, data in
                guard let hwnd else { return true }
                let slot = UnsafeMutablePointer<HWND?>(bitPattern: Int(data))
                guard let slot else { return true }
                guard WinWindowTargeting.listedWindow(hwnd, ownPid: GetCurrentProcessId()) != nil else { return true }
                slot.pointee = hwnd
                return false
            }, LPARAM(Int(bitPattern: pointer)))
        }
        return found
    }

    /// Visible top-level windows, sorted by title. Owned tool windows, the
    /// desktop, and this process are left out.
    static func visibleWindows() -> [ListedWindow] {
        var list: [ListedWindow] = []
        withUnsafeMutablePointer(to: &list) { pointer in
            _ = EnumWindows({ hwnd, data in
                guard let hwnd else { return true }
                let list = UnsafeMutablePointer<[ListedWindow]>(bitPattern: Int(data))
                guard let list else { return true }
                if let item = WinWindowTargeting.listedWindow(hwnd, ownPid: GetCurrentProcessId()) {
                    list.pointee.append(item)
                }
                return true
            }, LPARAM(Int(bitPattern: pointer)))
        }
        return list.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private static let gwOwner: UINT = 4
    private static let skippedClasses: Set<String> = [
        "Shell_TrayWnd",
        "Shell_SecondaryTrayWnd",
        "Progman",
        "WorkerW",
        "NotifyIconOverflowWindow",
    ]

    static func listedWindow(_ hwnd: HWND, ownPid: DWORD) -> ListedWindow? {
        guard IsWindowVisible(hwnd) else { return nil }
        if GetWindow(hwnd, gwOwner) != nil { return nil }
        let style = UInt32(bitPattern: GetWindowLongW(hwnd, GWL_EXSTYLE))
        if style & UInt32(WS_EX_TOOLWINDOW) != 0 { return nil }

        var cloaked: UInt32 = 0
        _ = DwmGetWindowAttribute(hwnd, DWORD(DWMWA_CLOAKED.rawValue), &cloaked, UInt32(MemoryLayout<UInt32>.size))
        if cloaked != 0 { return nil }

        var processId: DWORD = 0
        _ = GetWindowThreadProcessId(hwnd, &processId)
        if processId == 0 || processId == ownPid { return nil }

        var className = [WCHAR](repeating: 0, count: 128)
        if GetClassNameW(hwnd, &className, Int32(className.count)) > 0 {
            let name = className.string
            if skippedClasses.contains(name) { return nil }
        }

        if !IsIconic(hwnd) {
            var rect = RECT()
            if GetWindowRect(hwnd, &rect) {
                if rect.right - rect.left < 80 || rect.bottom - rect.top < 60 { return nil }
            }
        }

        var buffer = [WCHAR](repeating: 0, count: 256)
        let length = GetWindowTextW(hwnd, &buffer, Int32(buffer.count))
        guard length > 0 else { return nil }
        let title = buffer.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let process = processImageName(processId) ?? "window"
        guard let identity = identity(of: hwnd) else { return nil }
        return ListedWindow(hwnd: hwnd, title: title, processName: process, identity: identity)
    }

    static func window(_ hwnd: HWND) -> Target? {

        var rect = RECT()
        guard GetWindowRect(hwnd, &rect) else { return nil }

        var processName: String?
        var processId: DWORD = 0
        GetWindowThreadProcessId(hwnd, &processId)
        if processId != 0 {
            processName = processImageName(processId)
        }

        // Skip cloaked (DWM invisible) windows like UWP ghosts.
        var cloaked: UInt32 = 0
        _ = DwmGetWindowAttribute(hwnd, DWORD(DWMWA_CLOAKED.rawValue), &cloaked, UInt32(MemoryLayout<UInt32>.size))
        if cloaked != 0 { return nil }

        return Target(
            hwnd: hwnd,
            frame: Rect(
                x: Double(rect.left), y: Double(rect.top),
                width: Double(rect.right - rect.left),
                height: Double(rect.bottom - rect.top)
            ),
            processName: processName
        )
    }

    private static func processImageName(_ pid: DWORD) -> String? {
        let handle = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, pid)
        guard let handle else { return nil }
        defer { CloseHandle(handle) }

        var buffer = [WCHAR](repeating: 0, count: 1024)
        var size = DWORD(buffer.count)
        guard QueryFullProcessImageNameW(handle, 0, &buffer, &size) else { return nil }
        let path = buffer.prefix(Int(size)).map { UInt16($0) }.string
        return (path as NSString).lastPathComponent
    }
}

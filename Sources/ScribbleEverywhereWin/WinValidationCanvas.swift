import Foundation
import WinSDK

/// Isolated, opt-in clipboard receiver for end-to-end runtime checks. It runs
/// in its own process and does not read settings, save files, or hook pen input.
@MainActor
enum WinValidationCanvas {
    private static var hwnd: HWND?
    private static var status: HWND?
    private static var dib: Data?
    private static var pasteCount = 0

    static func run() {
        var wc = WNDCLASSEXW()
        wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        wc.lpfnWndProc = wndProc
        wc.hInstance = GetModuleHandleW(nil)
        wc.hbrBackground = GetSysColorBrush(Int32(COLOR_WINDOW))
        wc.hCursor = LoadCursorW(nil, UnsafePointer(bitPattern: 32512))
        "PalimpsestValidationCanvas".wide.withUnsafeBufferPointer {
            wc.lpszClassName = $0.baseAddress
            _ = RegisterClassExW(&wc)
        }
        hwnd = CreateWindowExW(0, "PalimpsestValidationCanvas".wide,
            "ScribbleEverywhere — Paste check".wide, DWORD(WS_OVERLAPPEDWINDOW) | DWORD(WS_CLIPCHILDREN),
            200, 150, 1200, 900, nil, nil, GetModuleHandleW(nil), nil)
        guard let hwnd else { return }
        status = CreateWindowExW(0, "STATIC".wide, "Ready — no image received".wide,
            DWORD(WS_CHILD | WS_VISIBLE), 20, 15, 1100, 50,
            hwnd, nil, GetModuleHandleW(nil), nil)
        if let font = WinTrayMenu.getMenuFont() {
            _ = SendMessageW(status, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: font)), 1)
        }
        ShowWindow(hwnd, SW_SHOWNORMAL)
        _ = SetForegroundWindow(hwnd)
        var message = MSG()
        while GetMessageW(&message, nil, 0, 0) {
            _ = TranslateMessage(&message)
            _ = DispatchMessageW(&message)
        }
    }

    private static func receiveImage() {
        guard OpenClipboard(hwnd) else { return }
        defer { CloseClipboard() }
        guard let handle = GetClipboardData(UINT(CF_DIB)), let bytes = GlobalLock(handle) else {
            _ = SetWindowTextW(status, "No CF_DIB image on clipboard".wide)
            return
        }
        defer { GlobalUnlock(handle) }
        let size = Int(GlobalSize(handle))
        guard size >= MemoryLayout<BITMAPINFOHEADER>.size, size <= 128 * 1024 * 1024 else { return }
        let header = bytes.load(as: BITMAPINFOHEADER.self)
        guard header.biSize >= 40, header.biSize <= size, header.biWidth > 0,
              header.biHeight != 0, header.biHeight != Int32.min,
              header.biPlanes == 1, header.biBitCount == 32,
              header.biCompression == UInt32(BI_RGB) else { return }
        let width = Int(header.biWidth), height = Int(abs(header.biHeight))
        guard width <= size / 4, height <= size / (width * 4) else { return }
        let required = Int(header.biSize) + width * height * 4
        guard required <= size else { return }
        dib = Data(bytes: bytes, count: required)
        pasteCount += 1
        _ = SetWindowTextW(status, "Image received: \(header.biWidth) × \(abs(header.biHeight)) — paste #\(pasteCount)".wide)
        _ = InvalidateRect(hwnd, nil, true)
    }

    private static func paint(_ window: HWND) {
        var ps = PAINTSTRUCT()
        guard let dc = BeginPaint(window, &ps) else { return }
        defer { EndPaint(window, &ps) }
        var rect = RECT()
        _ = GetClientRect(window, &rect)
        _ = FillRect(dc, &rect, GetSysColorBrush(Int32(COLOR_WINDOW)))
        guard let dib else { return }
        dib.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let header = base.load(as: BITMAPINFOHEADER.self)
            let width = Int(header.biWidth), height = Int(abs(header.biHeight))
            let availableWidth = max(Int(rect.right) - 40, 1)
            let availableHeight = max(Int(rect.bottom) - 90, 1)
            let scale = min(Double(availableWidth) / Double(width), Double(availableHeight) / Double(height), 1)
            _ = StretchDIBits(dc, 20, 75, Int32(Double(width) * scale), Int32(Double(height) * scale),
                0, 0, header.biWidth, Int32(height), base.advanced(by: Int(header.biSize)),
                base.assumingMemoryBound(to: BITMAPINFO.self), UINT(DIB_RGB_COLORS), DWORD(SRCCOPY))
        }
    }

    nonisolated private static let wndProc: WNDPROC = { window, message, wParam, lParam in
        guard let window else { return DefWindowProcW(nil, message, wParam, lParam) }
        return MainActor.assumeIsolated {
            switch message {
            case UINT(WM_PAINT): paint(window); return 0
            case UINT(WM_KEYDOWN):
                if UInt32(wParam) == 0x56 && (GetKeyState(Int32(VK_CONTROL)) & Int16(bitPattern: 0x8000)) != 0 {
                    receiveImage()
                    return 0
                }
                return DefWindowProcW(window, message, wParam, lParam)
            case UINT(WM_DESTROY): PostQuitMessage(0); return 0
            default: return DefWindowProcW(window, message, wParam, lParam)
            }
        }
    }
}

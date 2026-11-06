import Foundation
import WinSDK

/// The side button stops annotation only while the overlay is up, because that
/// is the only window that sees `PEN_FLAG_BARREL`. When annotation is off the
/// overlay is click-through, so this listens to the pen's HID reports directly.
enum PenBarrel {
    private static let wmInput: UINT = 0x00FF
    private static let ridInput: UINT = 0x10000003
    private static let ridiPreparsed: UINT = 0x20000005
    private static let rimTypeHid: UInt32 = 2
    private static let ridevInputSink: UInt32 = 0x00000100
    private static let digitizerPage: UInt16 = 0x0D
    private static let penUsage: UInt16 = 0x02
    private static let barrelSwitch: UInt16 = 0x44
    private static let hidpStatusSuccess: Int32 = 0x00110000

    nonisolated(unsafe) private static var preparsed: [UInt: [UInt8]] = [:]
    nonisolated(unsafe) private static var barrelDown = false
    nonisolated(unsafe) private static var loggedUsages: Set<UInt16> = []

    static func install(hwnd: HWND) {
        var device = PenBarrelDevice(
            usUsagePage: digitizerPage,
            usUsage: penUsage,
            dwFlags: ridevInputSink,
            hwndTarget: UInt64(UInt(bitPattern: hwnd))
        )
        let size = UINT(MemoryLayout<PenBarrelDevice>.size)
        let ok = withUnsafePointer(to: &device) {
            registerRawInputDevices($0, 1, size)
        }
        WinLog.log("pen barrel listen ok=\(ok != 0) err=\(GetLastError()) bytes=\(size)")
    }

    static func handle(message: UINT, lParam: LPARAM) -> Bool {
        guard message == wmInput else { return false }
        consume(lParam)
        return true
    }

    private static func consume(_ lParam: LPARAM) {
        let raw = HANDLE(bitPattern: Int(lParam))
        var size: UINT = 0
        _ = getRawInputData(raw, ridInput, nil, &size, 24)
        guard size > 24, size < 4096 else { return }
        var buffer = [UInt8](repeating: 0, count: Int(size))
        let read = buffer.withUnsafeMutableBytes { bytes in
            getRawInputData(raw, ridInput, bytes.baseAddress, &size, 24)
        }
        guard read != UInt32.max, read >= 32 else { return }
        let kind = buffer.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        guard kind == rimTypeHid else { return }
        let device = buffer.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt.self) }
        let reportSize = Int(buffer.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt32.self) })
        let reportCount = Int(buffer.withUnsafeBytes { $0.load(fromByteOffset: 28, as: UInt32.self) })
        guard reportSize > 0, reportCount > 0, 32 + reportSize * reportCount <= buffer.count else { return }
        guard let prepared = preparsedData(device: HANDLE(bitPattern: device)) else { return }

        var barrel = false
        for index in 0..<reportCount {
            let start = 32 + index * reportSize
            let report = Array(buffer[start..<(start + reportSize)])
            let usages = buttonUsages(report: report, preparsed: prepared)
            if usages.contains(barrelSwitch) { barrel = true }
            for usage in usages where loggedUsages.insert(usage).inserted {
                WinLog.log(String(format: "pen hid usage %04X", usage))
            }
        }
        if barrel && !barrelDown {
            barrelDown = true
            SurfacePenButton.noteTipPress("barrel")
        } else if !barrel {
            barrelDown = false
        }
    }

    private static func preparsedData(device: HANDLE?) -> [UInt8]? {
        let key = UInt(bitPattern: device)
        if let cached = preparsed[key] { return cached }
        var size: UINT = 0
        _ = getRawInputDeviceInfo(device, ridiPreparsed, nil, &size)
        guard size > 0, size < 1_048_576 else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(size))
        let written = bytes.withUnsafeMutableBytes { raw in
            getRawInputDeviceInfo(device, ridiPreparsed, raw.baseAddress, &size)
        }
        guard written != UInt32.max, written > 0 else { return nil }
        preparsed[key] = bytes
        return bytes
    }

    private static func buttonUsages(report: [UInt8], preparsed: [UInt8]) -> [UInt16] {
        var usages = [UInt16](repeating: 0, count: 32)
        var count: UInt32 = 32
        let status = preparsed.withUnsafeBytes { prepared in
            report.withUnsafeBytes { raw in
                hidpGetUsages(
                    0,
                    digitizerPage,
                    0,
                    &usages,
                    &count,
                    prepared.baseAddress.map { UnsafeMutableRawPointer(mutating: $0) },
                    raw.baseAddress.map { UnsafeMutablePointer<CChar>(OpaquePointer($0)) },
                    UInt32(report.count)
                )
            }
        }
        guard status == hidpStatusSuccess, count > 0 else { return [] }
        return Array(usages.prefix(Int(count)))
    }
}

private struct PenBarrelDevice {
    var usUsagePage: UInt16
    var usUsage: UInt16
    var dwFlags: UInt32
    var hwndTarget: UInt64
}

@_silgen_name("RegisterRawInputDevices")
private func registerRawInputDevices(
    _ devices: UnsafePointer<PenBarrelDevice>?,
    _ count: UINT,
    _ size: UINT
) -> Int32

@_silgen_name("GetRawInputData")
private func getRawInputData(
    _ raw: HANDLE?,
    _ command: UINT,
    _ data: UnsafeMutableRawPointer?,
    _ size: UnsafeMutablePointer<UINT>?,
    _ headerSize: UINT
) -> UINT

@_silgen_name("GetRawInputDeviceInfoW")
private func getRawInputDeviceInfo(
    _ device: HANDLE?,
    _ command: UINT,
    _ data: UnsafeMutableRawPointer?,
    _ size: UnsafeMutablePointer<UINT>?
) -> UINT

@_silgen_name("HidP_GetUsages")
private func hidpGetUsages(
    _ reportType: Int32,
    _ usagePage: UInt16,
    _ linkCollection: UInt16,
    _ usageList: UnsafeMutablePointer<UInt16>?,
    _ usageLength: UnsafeMutablePointer<UInt32>?,
    _ preparsed: UnsafeMutableRawPointer?,
    _ report: UnsafeMutablePointer<CChar>?,
    _ reportLength: UInt32
) -> Int32

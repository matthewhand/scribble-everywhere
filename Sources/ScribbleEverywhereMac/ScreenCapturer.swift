import Foundation
import CoreGraphics
import ScreenCaptureKit
import PalimpsestCore

struct ScreenCapturerError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Captures a screen region with ScreenCaptureKit.
///
/// Our own overlay window sits above the target, so it must be excluded from the
/// capture or the ink would be baked in *and* then composited again by
/// `BufferInkCompositor` (double ink). We exclude every window owned by this
/// process and composite the ink ourselves.
final class ScreenCapturer: PalimpsestCore.ScreenCapturer {
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void = { Diagnostics.log($0) }) {
        self.log = log
    }

    static func captureDisplay(for rect: Rect, in displays: [DisplayFrame]) -> DisplayFrame? {
        DisplayLookup.display(covering: rect, in: displays)
    }

    func capture(rect: Rect) async throws -> ImageBuffer {
        let displays = ScreenGeometry.displays()
        guard let display = Self.captureDisplay(for: rect, in: displays) else {
            throw ScreenCapturerError(message: "No display is available for the target region")
        }
        guard let plan = CaptureGeometry.plan(window: rect, display: display.frame, scale: display.scale) else {
            throw ScreenCapturerError(message: "Target region is empty")
        }
        guard let displayID = CGDirectDisplayID(exactly: display.id) else {
            throw ScreenCapturerError(message: "Unknown display identifier")
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let sckDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenCapturerError(message: "ScreenCaptureKit did not expose display \(displayID)")
        }
        let ownWindows = content.windows.filter {
            $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
        }

        let filter = SCContentFilter(display: sckDisplay, excludingWindows: ownWindows)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(
            x: plan.sourceRect.minX,
            y: plan.sourceRect.minY,
            width: plan.sourceRect.width,
            height: plan.sourceRect.height
        )
        configuration.width = plan.pixelWidth
        configuration.height = plan.pixelHeight
        configuration.showsCursor = false
        configuration.captureResolution = .best

        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            guard let buffer = ImageBuffer.from(image) else {
                throw ScreenCapturerError(message: "Could not decode the captured image")
            }
            return buffer
        } catch {
            log("ScreenCaptureKit capture failed: \(error.localizedDescription)")
            throw error
        }
    }
}

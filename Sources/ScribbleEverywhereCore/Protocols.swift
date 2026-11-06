import Foundation

/// Platform seams. `PalimpsestCore` defines what each shell must provide; the
/// macOS shell (`PalimpsestInk`) implements them with AppKit/ScreenCaptureKit/
/// Carbon. Windows and Linux shells would implement the same protocols.

/// Owns the transparent annotation layer for one display. UI work, so main
/// actor isolated.
@MainActor
public protocol OverlayHost: AnyObject {
    var isClickThrough: Bool { get set }
    /// Places the overlay over the display with the given identifier.
    func show(onDisplay displayID: UInt32)
    func clear()
}

/// Captures a region of the screen with the ink already composited in (because
/// the overlay is an on-screen window above the target).
public protocol ScreenCapturer {
    func capture(rect: Rect) async throws -> ImageBuffer
}

/// Registers a global hotkey.
public protocol HotkeyRegistrar: AnyObject {
    /// Returns false when the hotkey is already taken by another application.
    @discardableResult
    func register(_ hotkey: Hotkey) -> Bool
    func unregister()
}

/// Writes an image (and optionally PNG bytes) to the system clipboard.
public protocol ClipboardWriter {
    func write(image: ImageBuffer, png: Data?)
}

/// Reactivates a target application and sends the paste keystroke. Returns
/// whether ⌘V was actually posted, so callers can report honestly.
public protocol Paster {
    @discardableResult
    func paste(into applicationID: String?) async -> Bool
}

public enum PenPhase: Sendable {
    case down
    case move
    case up
    case proximityEnter
    case proximityExit
}

public struct PenSample: Sendable {
    public var location: Point
    public var pressure: Double
    public var isTablet: Bool
    public var phase: PenPhase

    public init(location: Point, pressure: Double, isTablet: Bool, phase: PenPhase) {
        self.location = location
        self.pressure = pressure
        self.isTablet = isTablet
        self.phase = phase
    }
}

/// A source of pointer/pen samples. On macOS this is fed by the overlay view's
/// event handlers; other shells would feed it from their own event loop.
public protocol PenInputSource: AnyObject {
    var onSample: ((PenSample) -> Void)? { get set }
}

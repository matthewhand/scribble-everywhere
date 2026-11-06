import AppKit
import PalimpsestCore

@MainActor
final class OverlayManager: PalimpsestCore.OverlayHost {
    private var window: OverlayWindow?
    private var view: InkLayerView?
    private var origin: Point = Point(x: 0, y: 0)

    var onStrokeChanged: (() -> Void)?
    var onCancel: (() -> Void)?
    var onUndo: (() -> Void)?
    var onClear: (() -> Void)?
    var onCopy: (() -> Void)?
    var onCopyAndPaste: (() -> Void)?
    var onPaletteColour: ((Int) -> Void)?

    var isClickThrough: Bool = true {
        didSet {
            if isClickThrough { view?.finishContact() }
            window?.ignoresMouseEvents = isClickThrough
        }
    }

    func attach(canvas: StrokeCanvas) {
        let view = InkLayerView(canvas: canvas)
        view.onStrokeChanged = { [weak self] in self?.onStrokeChanged?() }
        view.onCancel = { [weak self] in self?.onCancel?() }
        view.onUndo = { [weak self] in self?.onUndo?() }
        view.onClear = { [weak self] in self?.onClear?() }
        view.onCopy = { [weak self] in self?.onCopy?() }
        view.onCopyAndPaste = { [weak self] in self?.onCopyAndPaste?() }
        self.view = view

        let frame = ScreenGeometry.unionVisibleFrame()
        origin = frame.origin
        view.globalOrigin = origin

        let window = OverlayWindow(contentRect: ScreenGeometry.cocoaFrame(fromTopLeft: frame))
        window.contentView = view
        self.window = window
    }

    func show(onDisplay displayID: UInt32) {
        guard let window, let view else { return }

        // Re-read the geometry on every show: displays may have changed since we
        // were attached, and the view maps global points using this origin.
        // Cover the requested display when it exists, else the union of all
        // screens; a single-display machine sees no difference.
        let frame: Rect
        if let display = ScreenGeometry.displays().first(where: { $0.id == displayID }) {
            frame = display.frame
        } else {
            frame = ScreenGeometry.unionVisibleFrame()
        }
        origin = frame.origin
        view.globalOrigin = origin
        window.setFrame(ScreenGeometry.cocoaFrame(fromTopLeft: frame), display: true)

        window.alphaValue = 1
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(view)
    }

    func hide() {
        view?.finishContact()
        window?.orderOut(nil)
    }

    func clear() {
        view?.needsDisplay = true
    }

    func discardContact() {
        view?.discardContact()
    }

    func refresh() {
        view?.needsDisplay = true
    }
}

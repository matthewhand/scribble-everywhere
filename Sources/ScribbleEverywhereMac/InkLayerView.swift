import AppKit
import PalimpsestCore

/// The drawing surface. It renders from a `StrokeCanvas`, so stroke storage,
/// undo and pressure rules all live in `PalimpsestCore` and are unit tested.
///
/// Pen input on macOS with `waltopd` arrives as `tabletPoint`/`tabletProximity`
/// events only — no mouse events — so the pen is drawn here. A plain mouse is
/// drawn through the mouse handlers. While a pen is in proximity the mouse
/// handlers are ignored, which also de-duplicates the case where a native tablet
/// driver delivers both kinds of event.
final class InkLayerView: NSView, PalimpsestCore.PenInputSource {
    let canvas: StrokeCanvas

    var onStrokeChanged: (() -> Void)?
    var onCancel: (() -> Void)?
    var onUndo: (() -> Void)?
    var onClear: (() -> Void)?
    var onCopy: (() -> Void)?
    var onCopyAndPaste: (() -> Void)?
    var onSample: ((PenSample) -> Void)?

    /// Origin of this view in top-left global coordinates, used to map global
    /// stroke points into view space.
    var globalOrigin: Point = Point(x: 0, y: 0)

    private var tabletActive = false
    private var strokeActive = false
    private var contactIsTablet = false
    private var suppressTabletUntilLift = false
    private var lastPoint: Point?
    private var lastPressure: Double = 0

    init(canvas: StrokeCanvas) {
        self.canvas = canvas
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Hiding can interrupt a contact before its up event reaches this view.
    func finishContact() {
        let hadContact = strokeActive
        if hadContact, let last = canvas.current?.points.last { canvas.end(at: last) }
        discardContact(suppressTablet: false)
        // Proximity-exit may occur while the overlay is hidden. Do not leave
        // mouse input disabled in the next annotation session.
        tabletActive = false
        needsDisplay = true
        if hadContact { onStrokeChanged?() }
    }

    /// Undo and clear remove the canvas's in-progress stroke, so subsequent
    /// drag events must not continue a contact that no longer exists.
    func discardContact(suppressTablet: Bool = true) {
        if suppressTablet, strokeActive, contactIsTablet {
            suppressTabletUntilLift = true
        } else if !suppressTablet {
            suppressTabletUntilLift = false
        }
        strokeActive = false
        contactIsTablet = false
        lastPoint = nil
        lastPressure = 0
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard !tabletActive, !strokeActive else { return }
        let point = location(of: event)
        canvas.begin(at: StrokePoint(location: point, pressure: 0, isTablet: false))
        strokeActive = true
        contactIsTablet = false
        lastPoint = point
        invalidate(from: point, to: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !tabletActive, strokeActive, !contactIsTablet else { return }
        let point = location(of: event)
        canvas.extend(to: StrokePoint(location: point, pressure: 0, isTablet: false))
        invalidate(from: lastPoint ?? point, to: point)
        lastPoint = point
    }

    override func mouseUp(with event: NSEvent) {
        guard !tabletActive, strokeActive, !contactIsTablet else { return }
        let point = location(of: event)
        canvas.end(at: StrokePoint(location: point, pressure: 0, isTablet: false))
        invalidate(from: lastPoint ?? point, to: point)
        strokeActive = false
        lastPoint = nil
        onStrokeChanged?()
    }

    // MARK: Tablet (pen)

    override func tabletPoint(with event: NSEvent) {
        let buttons = TabletButtons.decode(bits: rawButtonBits(of: event))
        handleTabletPoint(location: location(of: event), pressure: Double(event.pressure), tip: buttons.tip)
    }

    /// The tip remains physically down after undo or clear. Ignore its samples
    /// until release so the deleted stroke does not immediately grow a tail.
    func handleTabletPoint(location point: Point, pressure: Double, tip: Bool) {
        // A session can start while the pen is already in range, after its
        // proximity-enter event was delivered to some other window.
        if !tabletActive {
            if strokeActive, !contactIsTablet {
                if let last = canvas.current?.points.last { canvas.end(at: last) }
                discardContact()
                needsDisplay = true
                onStrokeChanged?()
            }
            tabletActive = true
        }
        onSample?(PenSample(location: point, pressure: pressure, isTablet: true, phase: tip ? .move : .up))
        if suppressTabletUntilLift {
            if !tip { suppressTabletUntilLift = false }
            return
        }
        // Events from another pointer must not take over an active stroke.
        guard !strokeActive || contactIsTablet else { return }
        if tip {
            let strokePoint = StrokePoint(location: point, pressure: pressure, isTablet: true)
            if strokeActive {
                canvas.extend(to: strokePoint)
            } else {
                canvas.begin(at: strokePoint)
                strokeActive = true
                contactIsTablet = true
                lastPoint = point
            }
            lastPressure = pressure
            invalidate(from: lastPoint ?? point, to: point)
            lastPoint = point
        } else if strokeActive {
            // End at the last real pressure, not 0, or the final segment flares
            // to the fixed fallback width.
            canvas.end(at: StrokePoint(location: point, pressure: lastPressure, isTablet: true))
            invalidate(from: lastPoint ?? point, to: point)
            strokeActive = false
            contactIsTablet = false
            lastPoint = nil
            onStrokeChanged?()
        }
    }

    override func tabletProximity(with event: NSEvent) {
        updateTabletProximity(isEntering: event.isEnteringProximity, location: location(of: event))
    }

    func updateTabletProximity(isEntering: Bool, location point: Point) {
        // A pen entering proximity suppresses mouse events. Complete an active
        // mouse contact first so its eventual mouse-up cannot leave it stuck.
        if isEntering, strokeActive, !contactIsTablet {
            if let last = canvas.current?.points.last { canvas.end(at: last) }
            discardContact()
            needsDisplay = true
            onStrokeChanged?()
        }
        tabletActive = isEntering
        if !tabletActive { suppressTabletUntilLift = false }
        if !tabletActive, strokeActive, contactIsTablet {
            // A proximity event is not a tablet sample and its position need
            // not match the last pen location. Never draw a segment to it.
            if let last = canvas.current?.points.last { canvas.end(at: last) }
            strokeActive = false
            contactIsTablet = false
            lastPoint = nil
            needsDisplay = true
            onStrokeChanged?()
        }
        onSample?(PenSample(
            location: point,
            pressure: 0,
            isTablet: tabletActive,
            phase: tabletActive ? .proximityEnter : .proximityExit
        ))
    }

    /// The raw `tabletEventPointButtons` bits from the underlying CGEvent.
    private func rawButtonBits(of event: NSEvent) -> Int {
        Int(event.cgEvent?.getIntegerValueField(.tabletEventPointButtons) ?? 0)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        // Keep the pen in hand: the editing actions are reachable from the
        // keyboard while annotating.
        if event.modifierFlags.contains(.command) {
            switch event.keyCode {
            case 6:  onUndo?()          // ⌘Z
            case 51: onClear?()         // ⌘⌫
            case 8:  onCopy?()          // ⌘C
            case 36: onCopyAndPaste?()  // ⌘↩
            default: super.keyDown(with: event)
            }
            return
        }

        if event.keyCode == 53 { // Escape
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Actually erase the dirty region; filling with a clear colour is a
        // no-op in a non-opaque view, which would leave undone strokes behind.
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        for stroke in canvas.allStrokes() {
            drawStroke(stroke)
        }
    }

    private func drawStroke(_ stroke: Stroke) {
        let points = stroke.points
        guard !points.isEmpty else { return }
        let color = NSColor(
            srgbRed: CGFloat(stroke.ink.r) / 255,
            green: CGFloat(stroke.ink.g) / 255,
            blue: CGFloat(stroke.ink.b) / 255,
            alpha: CGFloat(stroke.ink.a) / 255
        )
        color.setStroke()
        color.setFill()

        if points.count == 1 {
            let width = width(for: points[0])
            let origin = viewPoint(points[0].location)
            let dot = NSBezierPath(
                ovalIn: NSRect(
                    x: origin.x - width / 2,
                    y: origin.y - width / 2,
                    width: width,
                    height: width
                )
            )
            dot.fill()
            return
        }

        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let width = (width(for: previous) + width(for: current)) / 2
            let path = NSBezierPath()
            path.lineWidth = max(width, 0.5)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: viewPoint(previous.location))
            path.line(to: viewPoint(current.location))
            path.stroke()
        }
    }

    private func width(for point: StrokePoint) -> CGFloat {
        CGFloat(canvas.style.width(pressure: point.pressure, isTablet: point.isTablet))
    }

    /// Invalidate the whole segment, not just the newest point, so a fast drag
    /// still redraws the part that was previously outside the dirty rect.
    private func invalidate(from a: Point, to b: Point) {
        let radius = CGFloat(canvas.style.maxWidth) + 2
        let p0 = viewPoint(a)
        let p1 = viewPoint(b)
        setNeedsDisplay(NSRect(
            x: min(p0.x, p1.x) - radius,
            y: min(p0.y, p1.y) - radius,
            width: abs(p0.x - p1.x) + radius * 2,
            height: abs(p0.y - p1.y) + radius * 2
        ))
    }

    private func location(of event: NSEvent) -> Point {
        let local = convert(event.locationInWindow, from: nil)
        return Point(x: Double(local.x) + globalOrigin.x, y: Double(local.y) + globalOrigin.y)
    }

    private func viewPoint(_ point: Point) -> NSPoint {
        NSPoint(x: CGFloat(point.x - globalOrigin.x), y: CGFloat(point.y - globalOrigin.y))
    }
}

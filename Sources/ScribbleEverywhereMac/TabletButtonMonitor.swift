import AppKit
import CoreGraphics
import PalimpsestCore

/// Plans synthetic mouse events in contact order. In particular, a new pen
/// contact must post mouse-down before any drag, and the final position must
/// be delivered as mouse-up rather than a hover move.
struct TabletMouseState {
    private(set) var tipDown = false
    private var lastPosition: CGPoint?

    mutating func update(position: CGPoint, tip: Bool) -> [(CGEventType, CGPoint)] {
        let previousTip = tipDown
        let moved = lastPosition != position
        lastPosition = position
        tipDown = tip
        if tip != previousTip {
            return [(tip ? .leftMouseDown : .leftMouseUp, position)]
        }
        if moved {
            return [(tip ? .leftMouseDragged : .mouseMoved, position)]
        }
        return []
    }

    mutating func reset(at position: CGPoint) -> (CGEventType, CGPoint)? {
        let needsRelease = tipDown
        tipDown = false
        lastPosition = nil
        return needsRelease ? (.leftMouseUp, position) : nil
    }
}

/// Watches stylus button presses system-wide via a read-only CGEvent tap.
///
/// A tap is used rather than the overlay's event handlers because the overlay is
/// hidden when annotation is off — yet that is exactly when the pen button has to
/// be able to turn it *on*. The tap never consumes events (`.listenOnly`).
///
/// The button state is read from `tabletEventPointButtons`.
final class TabletButtonMonitor {
    var onBarrel1: (() -> Void)?
    var onBarrel2: (() -> Void)?
    var shouldControlMouse: (() -> Bool)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var edges = ButtonEdgeDetector()
    private var mouseState = TabletMouseState()

    func start() {
        guard tap == nil else { return }

        let mask = (1 << CGEventType.tabletPointer.rawValue) | (1 << CGEventType.tabletProximity.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<TabletButtonMonitor>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                monitor.resetEdges()
                monitor.reenable()
                return Unmanaged.passUnretained(event)
            }
            if type == .tabletProximity {
                monitor.resetEdges()
            } else {
                monitor.handle(event)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Diagnostics.log("Could not install tablet button tap (needs Accessibility)")
            return
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        resetEdges()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    private func reenable() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    /// A pen entering or leaving range resets the edge state, so a button held
    /// as the pen leaves does not swallow the next press.
    func resetEdges() {
        edges.reset()
        releaseTipIfNeeded()
    }

    private func releaseTipIfNeeded() {
        if let (type, position) = mouseState.reset(at: currentCursorLocation()) {
            postMouse(type: type, at: position)
        }
    }

    private func currentCursorLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func postMouse(type: CGEventType, at position: CGPoint) {
        guard let event = CGEvent(
            mouseEventSource: CGEventSource(stateID: .hidSystemState),
            mouseType: type,
            mouseCursorPosition: position,
            mouseButton: .left
        ) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.post(tap: .cghidEventTap)
    }

    private func handle(_ event: CGEvent) {
        let bits = Int(event.getIntegerValueField(.tabletEventPointButtons))
        let buttons = TabletButtons.decode(bits: bits)
        let pressed = edges.update(buttons)
        if bits != 0 {
            Diagnostics.log("Tablet pointer buttons: bits=\(bits) b1Pressed=\(pressed.barrel1Pressed) b2Pressed=\(pressed.barrel2Pressed)")
        }
        if pressed.barrel1Pressed { onBarrel1?() }
        if pressed.barrel2Pressed { onBarrel2?() }
        guard shouldControlMouse?() == true else {
            releaseTipIfNeeded()
            return
        }

        for (type, position) in mouseState.update(position: event.location, tip: buttons.tip) {
            postMouse(type: type, at: position)
        }
    }
}

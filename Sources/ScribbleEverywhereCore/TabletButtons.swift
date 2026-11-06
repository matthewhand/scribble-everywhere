import Foundation

/// Decoded state of a tablet pointer event's button bits.
///
/// The bits come from CoreGraphics' `tabletEventPointButtons`, whose low bits
/// survive the trip into `NSEvent` (unlike `mouseEventButtonNumber`, which
/// AppKit discards on tablet events). Bit 0 is the tip, bit 1 and bit 2 are
/// barrel buttons.
public struct TabletButtons: Equatable, Sendable {
    public var tip: Bool
    public var barrel1: Bool
    public var barrel2: Bool

    public init(tip: Bool, barrel1: Bool, barrel2: Bool) {
        self.tip = tip
        self.barrel1 = barrel1
        self.barrel2 = barrel2
    }

    public static let none = TabletButtons(tip: false, barrel1: false, barrel2: false)

    public static func decode(bits: Int) -> TabletButtons {
        TabletButtons(
            tip: bits & 0b001 != 0,
            barrel1: bits & 0b010 != 0,
            barrel2: bits & 0b100 != 0
        )
    }
}

/// Edge detector for the barrel buttons. `update` reports a press only on the
/// transition from up to down, so holding a button does not repeat the action.
public struct ButtonEdgeDetector {
    private var previous: TabletButtons

    public init(previous: TabletButtons = .none) {
        self.previous = previous
    }

    public mutating func update(_ current: TabletButtons) -> (barrel1Pressed: Bool, barrel2Pressed: Bool) {
        let pressed = (
            barrel1Pressed: current.barrel1 && !previous.barrel1,
            barrel2Pressed: current.barrel2 && !previous.barrel2
        )
        previous = current
        return pressed
    }

    /// Forget the last state, so the next press is treated as a fresh rising
    /// edge. Used when the pen leaves proximity with a button still held.
    public mutating func reset() {
        previous = .none
    }
}

import Foundation

/// An ordered set of ink colours with a selected index. The selection is what
/// the canvas draws with; the applet menu and Settings edit it.
///
/// Platform-free so the selection/cycle rules are unit tested; the macOS shell
/// persists it and renders the swatches.
public struct Palette: Equatable, Sendable {
    public private(set) var colors: [RGBA]
    public private(set) var index: Int

    /// The three colours offered out of the box.
    public static let defaultColors: [RGBA] = [.red, .blue, .green]

    public init(colors: [RGBA], index: Int = 0) {
        self.colors = colors.isEmpty ? Palette.defaultColors : colors
        self.index = min(max(index, 0), self.colors.count - 1)
    }

    public static let standard = Palette(colors: defaultColors)

    public var current: RGBA { colors[index] }

    public var isEmpty: Bool { colors.isEmpty }

    public mutating func select(_ index: Int) {
        guard colors.indices.contains(index) else { return }
        self.index = index
    }

    /// Advances to the next colour, wrapping around.
    public mutating func cycle() {
        guard !colors.isEmpty else { return }
        index = (index + 1) % colors.count
    }

    /// Adds a colour if it is not already present, and selects it.
    public mutating func add(_ color: RGBA, select: Bool = true) {
        if let existing = colors.firstIndex(of: color) {
            if select { index = existing }
            return
        }
        colors.append(color)
        if select { index = colors.count - 1 }
    }

    /// Replaces the colour at `position` in place and keeps the selection
    /// there. Used by a colour picker, which streams a new value on every
    /// tick of a drag — replacing (rather than adding) keeps one swatch per
    /// edit. If the new colour already exists in the palette, the selection
    /// moves to it instead of creating a duplicate.
    public mutating func replace(at position: Int, with color: RGBA) {
        guard colors.indices.contains(position) else { return }
        if let existing = colors.firstIndex(of: color), existing != position {
            index = existing
            return
        }
        colors[position] = color
        index = position
    }

    /// Removes a colour. The last colour cannot be removed. The selection is
    /// kept pointing at the same colour where possible.
    public mutating func remove(at position: Int) {
        guard colors.count > 1, colors.indices.contains(position) else { return }
        colors.remove(at: position)
        if position < index {
            index -= 1
        } else if index >= colors.count {
            index = colors.count - 1
        }
    }

    /// Indices of colours that are not one of the built-in defaults. Defaults
    /// can be removed or edited, so custom colours are not tied to positions.
    public var customIndices: [Int] {
        colors.indices.filter { !Palette.defaultColors.contains(colors[$0]) }
    }
}

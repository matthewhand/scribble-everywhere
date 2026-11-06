import AppKit
import SwiftUI
import PalimpsestCore

@MainActor
final class FloatingPaletteController {
    private var panel: FloatingPalettePanel?
    private var hosting: NSHostingView<FloatingPaletteView>?
    private var onSelect: ((Int) -> Void)?
    private var onClear: (() -> Void)?
    private var onSave: (() -> Void)?

    func show(
        position: FloatingPalettePosition,
        displayID: UInt32? = nil,
        palette: Palette,
        names: [String: String],
        onSelect: @escaping (Int) -> Void,
        onClear: @escaping () -> Void,
        onSave: @escaping () -> Void
    ) {
        self.onSelect = onSelect
        self.onClear = onClear
        self.onSave = onSave
        guard position != .none else {
            hide()
            return
        }
        let view = FloatingPaletteView(
            palette: palette,
            names: names,
            onSelect: { [weak self] index in self?.onSelect?(index) },
            onClear: { [weak self] in self?.onClear?() },
            onSave: { [weak self] in self?.onSave?() }
        )

        let count = palette.colors.count
        let width = Self.width(colourCount: count)
        let targetScreen = displayID.flatMap { id in
            NSScreen.screens.first { screen in
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }
        }
        let screen = targetScreen ?? NSScreen.main ?? NSScreen.screens.first
        let frame = Self.frame(position: position, width: width, visibleFrame: screen?.visibleFrame ?? .zero)

        if let panel, let hosting {
            hosting.rootView = view
            panel.onTabletSelect = onSelect
            panel.onTabletClear = onClear
            panel.onTabletSave = onSave
            panel.paletteCount = count
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
            self.panel = panel
            self.hosting = hosting
            return
        }

        let hosting = NSHostingView(rootView: view)
        let panel = FloatingPalettePanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.onTabletSelect = onSelect
        panel.onTabletClear = onClear
        panel.onTabletSave = onSave
        panel.paletteCount = count
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.contentView = hosting
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        self.hosting = hosting
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
    }

    /// Keep the selected edge anchored even when the swatch count changes.
    static func width(colourCount: Int) -> CGFloat {
        // Swatches, all HStack gaps, the minimum spacer, buttons and padding.
        CGFloat(colourCount) * 34 + 88
    }

    static func frame(position: FloatingPalettePosition, width: CGFloat, visibleFrame: NSRect) -> NSRect {
        let x = position == .topLeft ? visibleFrame.minX + 16 : visibleFrame.maxX - width - 16
        return NSRect(x: x, y: visibleFrame.maxY - 64, width: width, height: 48)
    }
}

struct FloatingPaletteTabletEdge {
    private var tipDown = false

    mutating func press(tip: Bool) -> Bool {
        let pressed = tip && !tipDown
        tipDown = tip
        return pressed
    }

    mutating func reset() { tipDown = false }
}

private final class FloatingPalettePanel: NSPanel {
    var onTabletSelect: ((Int) -> Void)?
    var onTabletClear: (() -> Void)?
    var onTabletSave: (() -> Void)?
    var paletteCount = 0
    private var tabletEdge = FloatingPaletteTabletEdge()

    override func tabletPoint(with event: NSEvent) {
        let tip = TabletButtons.decode(bits: Int(event.cgEvent?.getIntegerValueField(.tabletEventPointButtons) ?? 0)).tip
        guard tabletEdge.press(tip: tip) else { return }
        let point = event.locationInWindow
        let width = frame.width
        let swatchEnd = CGFloat(paletteCount) * 34 - 8 + 10
        if point.x >= 10, point.x < swatchEnd {
            let index = Int((point.x - 10) / 34)
            guard (0..<paletteCount).contains(index) else { return }
            onTabletSelect?(index)
        } else if point.x >= width - 62, point.x < width - 40 {
            onTabletClear?()
        } else if point.x >= width - 32, point.x <= width - 10 {
            onTabletSave?()
        }
    }

    override func tabletProximity(with event: NSEvent) {
        if !event.isEnteringProximity { tabletEdge.reset() }
    }
}

private struct FloatingPaletteView: View {
    let palette: Palette
    let names: [String: String]
    let onSelect: (Int) -> Void
    let onClear: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(palette.colors.enumerated()), id: \.offset) { index, color in
                Button { onSelect(index) } label: {
                    Circle()
                        .fill(Color(color))
                        .frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(index == palette.index ? Color.accentColor : Color.white.opacity(0.7), lineWidth: index == palette.index ? 3 : 1))
                }
                .buttonStyle(.plain)
                .help(names[color.hex] ?? ColourNames.name(for: color))
            }

            Spacer(minLength: 8)

            Button { onClear() } label: {
                Image(systemName: "clear")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Clear ink")

            Button { onSave() } label: {
                Image(systemName: "floppydisk")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Save to folder")
        }
        .padding(10)
        .background(.regularMaterial, in: Capsule())
    }
}

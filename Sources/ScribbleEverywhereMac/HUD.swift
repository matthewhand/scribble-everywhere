import AppKit

/// A brief, non-interactive on-screen message (e.g. "Copied to clipboard").
/// It never takes focus and never eats clicks, and it is excluded from captures
/// because it belongs to this process.
@MainActor
final class HUD {
    static let shared = HUD()

    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    private init() {}

    func show(_ text: String, duration: TimeInterval = 1.2) {
        let panel = existingOrMakePanel()
        guard let label = panel.contentView?.subviews.first as? NSTextField else { return }
        label.stringValue = text

        sizeToFit(panel: panel, label: label)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                panel?.animator().alphaValue = 0
            } completionHandler: {
                panel?.orderOut(nil)
            }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func existingOrMakePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        effect.addSubview(label)
        panel.contentView = effect

        self.panel = panel
        return panel
    }

    private func sizeToFit(panel: NSPanel, label: NSTextField) {
        label.sizeToFit()
        let paddingX: CGFloat = 18
        let paddingY: CGFloat = 10
        let size = NSSize(
            width: label.frame.width + paddingX * 2,
            height: label.frame.height + paddingY * 2
        )
        label.frame = NSRect(x: paddingX, y: paddingY, width: label.frame.width, height: label.frame.height)

        let screen = NSScreen.main ?? NSScreen.screens.first
        if let frame = screen?.visibleFrame {
            let origin = NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.maxY - size.height - 24
            )
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }
    }
}

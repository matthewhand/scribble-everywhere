import AppKit
import Combine
import PalimpsestCore

@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    let settings: SettingsStore

    @Published private(set) var isCapturing = false
    @Published private(set) var strokeCount = 0
    @Published private(set) var hasInk = false
    @Published private(set) var hotkeyRegistered = false

    // Created lazily so the Carbon event target / AppKit windows are only
    // touched after the app has finished launching (see `start()`).
    private let canvas = StrokeCanvas()
    private lazy var overlay = OverlayManager()
    private lazy var capturer = ScreenCapturer()
    private lazy var clipboard = ClipboardImageWriter()
    private lazy var paster = Paster()
    private lazy var floatingPalette = FloatingPaletteController()
    let history: AnnotationHistory
    private lazy var hotkeys = HotkeyRegistrar()
    private lazy var tabletButtons = TabletButtonMonitor()

    private var activeHotkey: Hotkey?
    private var previousApplicationID: String?
    private var previousApplicationPID: pid_t?
    private var targetDisplayID: UInt32?
    private var sessionWindow: WindowIdentity?
    private var cancellables = Set<AnyCancellable>()
    private var didStart = false
    private var isRendering = false

    private init() {
        settings = SettingsStore()
        history = AnnotationHistory(folder: settings.annotationFolder)
        settings.$annotationFolder
            .dropFirst()
            .sink { [weak history] folder in history?.setFolder(folder) }
            .store(in: &cancellables)
    }

    var hotkeyDisplay: String { settings.hotkey.displayString }

    // MARK: Lifecycle

    func start() {
        guard !didStart else { return }
        didStart = true

        if !Permissions.hasAccessibility() {
            Permissions.requestAccessibility()
        }
        if !Permissions.hasScreenRecording() {
            Permissions.requestScreenRecording()
        }

        overlay.attach(canvas: canvas)
        overlay.onStrokeChanged = { [weak self] in self?.refreshState() }
        overlay.onCancel = { [weak self] in self?.cancelCapture() }
        overlay.onUndo = { [weak self] in self?.undo() }
        overlay.onClear = { [weak self] in self?.clear() }
        overlay.onCopy = { [weak self] in self?.copyToClipboard() }
        overlay.onCopyAndPaste = { [weak self] in self?.copyAndPaste() }

        hotkeys.onHotkey = { [weak self] in self?.toggleCaptureMode() }

        // Pen barrel buttons: 1st toggles annotation (stop = copy, and paste
        // when "paste on stop" is enabled), 2nd clears the ink.
        tabletButtons.onBarrel1 = { [weak self] in self?.toggleCaptureMode() }
        tabletButtons.onBarrel2 = { [weak self] in self?.clear() }
        tabletButtons.shouldControlMouse = { [weak self] in
            self?.settings.penMouseMode == true && self?.isCapturing == false
        }
        tabletButtons.start()

        settings.$hotkey
            .dropFirst()
            // Published emits before assignment. Defer so a failed registration
            // can restore the previous value after this assignment completes.
            .receive(on: RunLoop.main)
            .sink { [weak self] hotkey in
                guard let self, self.settings.hotkey == hotkey else { return }
                self.applyHotkey(hotkey)
            }
            .store(in: &cancellables)

        canvas.ink = settings.palette.current
        settings.$palette
            .dropFirst()
            .sink { [weak self] palette in
                guard let self else { return }
                self.canvas.ink = palette.current
                if self.isCapturing {
                    self.floatingPalette.show(position: self.settings.floatingPalettePosition, displayID: self.targetDisplayID, palette: palette, names: self.settings.colourNames, onSelect: { [weak self] index in
                        self?.settings.selectColour(at: index)
                    }, onClear: { [weak self] in
                        self?.clear()
                    }, onSave: { [weak self] in
                        self?.saveToFolder()
                    })
                }
            }
            .store(in: &cancellables)

        settings.$floatingPalettePosition
            .dropFirst()
            .sink { [weak self] position in
                guard let self, self.isCapturing else { return }
                self.floatingPalette.show(position: position, displayID: self.targetDisplayID, palette: self.settings.palette, names: self.settings.colourNames, onSelect: { [weak self] index in
                    self?.settings.selectColour(at: index)
                }, onClear: { [weak self] in
                    self?.clear()
                }, onSave: { [weak self] in
                    self?.saveToFolder()
                })
            }
            .store(in: &cancellables)

        settings.$colourNames
            .dropFirst()
            .sink { [weak self] names in
                guard let self, self.isCapturing else { return }
                self.floatingPalette.show(position: self.settings.floatingPalettePosition, displayID: self.targetDisplayID, palette: self.settings.palette, names: names, onSelect: { [weak self] index in
                    self?.settings.selectColour(at: index)
                }, onClear: { [weak self] in
                    self?.clear()
                }, onSave: { [weak self] in
                    self?.saveToFolder()
                })
            }
            .store(in: &cancellables)

        applyHotkey(settings.hotkey)
        refreshState()
    }

    func stop() {
        guard didStart else { return }
        hotkeys.unregister()
        tabletButtons.stop()
        overlay.hide()
    }

    // MARK: Capture mode

    /// The hotkey and the top menu item toggle annotation on/off. Leaving
    /// annotation with ink copies to the clipboard (matching barrel button 1).
    /// The ink itself persists until it is explicitly cleared.
    func toggleCaptureMode() {
        guard !isRendering else { return }
        guard isCapturing else {
            startCapture()
            return
        }
        if canvas.hasContent {
            finishSession()
        } else {
            stopCapture()
        }
    }

    func startCapture() {
        guard !isRendering else { return }
        let target = WindowTargeting.frontmostWindow()
        sessionWindow = target?.identity
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let frontmostID = frontmostApp?.bundleIdentifier
        previousApplicationID = WindowTargeting.previousApplication(frontmost: frontmostID, own: Bundle.main.bundleIdentifier, target: target?.bundleIdentifier)
        previousApplicationPID = frontmostID == nil || frontmostID == Bundle.main.bundleIdentifier
            ? target?.identity.processID : frontmostApp?.processIdentifier
        targetDisplayID = target.flatMap { target in
            DisplayLookup.display(covering: target.frame, in: ScreenGeometry.displays())?.id
        }
        overlay.refresh()
        isCapturing = true
        floatingPalette.show(position: settings.floatingPalettePosition, displayID: targetDisplayID, palette: settings.palette, names: settings.colourNames, onSelect: { [weak self] index in
            self?.settings.selectColour(at: index)
        }, onClear: { [weak self] in
            self?.clear()
        }, onSave: { [weak self] in
            self?.saveToFolder()
        })
        overlay.isClickThrough = false
        // A leftover colour picker panel would float above the overlay.
        if NSColorPanel.shared.isVisible { NSColorPanel.shared.close() }
        // Put the overlay on the display the window we are about to annotate
        // lives on, so the ink lands at the right origin/scale on a second
        // monitor. Falls back to the primary display when there is no target.
        overlay.show(onDisplay: targetDisplayID ?? 0)
        NSApp.activate(ignoringOtherApps: true)
        refreshState()
    }

    func stopCapture() {
        isCapturing = false
        overlay.isClickThrough = true
        overlay.hide()
        floatingPalette.hide()
        refreshState()
    }

    /// Escape stops annotating without copying; the ink is kept so the next
    /// session continues on top of it (clear it with barrel 2 or the menu).
    func cancelCapture() {
        stopCapture()
    }

    /// Stopping a session that has ink uses the selected delivery action.
    private func finishSession() {
        performAction()
    }

    /// Shows exactly what TCC currently grants this (re-signed) binary.
    func checkPermissions() {
        let screen = Permissions.hasScreenRecording() ? "granted" : "DENIED"
        let access = Permissions.hasAccessibility() ? "granted" : "DENIED"
        HUD.shared.show("Screen Recording: \(screen) — Accessibility: \(access)")
    }

    func performAction() {
        switch settings.action {
        case .clipboard: copyToClipboard()
        case .copyAndPaste: copyAndPaste()
        }
    }

    func copyAndPaste() {
        Task { await renderAndDeliver(paste: true, save: settings.saveAnnotations) }
    }

    func copyToClipboard() {
        Task { await renderAndDeliver(paste: false, save: settings.saveAnnotations) }
    }

    func saveToFolder() {
        Task { await renderAndDeliver(paste: false, save: true, clipboard: false) }
    }

    private func renderAndDeliver(paste: Bool, save: Bool, clipboard: Bool = true) async {
        guard !isRendering else { return }
        isRendering = true
        let requiresSession = isCapturing
        let captureSession = sessionWindow
        // Freeze the current contact and prevent edits while the asynchronous
        // screen capture is in progress. The export must reflect one session.
        overlay.isClickThrough = true
        defer {
            isRendering = false
            stopCapture()
        }

        guard let target = WindowTargeting.frontmostWindow() else {
            Diagnostics.log("No frontmost window to capture")
            HUD.shared.show("Nothing to copy")
            return
        }
        if isCapturing && !WindowTargeting.matchesSession(target.identity, session: sessionWindow) {
            Diagnostics.log("Annotation target changed before capture")
            HUD.shared.show("Window changed — ink kept")
            return
        }

        // Use the same clamp the capturer uses, so the ink is composited at the
        // exact origin/scale of the returned pixels (not the raw window frame).
        let displays = ScreenGeometry.displays()
        guard let display = ScreenCapturer.captureDisplay(for: target.frame, in: displays),
              let plan = CaptureGeometry.plan(window: target.frame, display: display.frame, scale: display.scale) else {
            Diagnostics.log("Target window has no capturable region")
            HUD.shared.show("Nothing to copy")
            return
        }
        let captureOrigin = Point(
            x: display.frame.minX + plan.sourceRect.minX,
            y: display.frame.minY + plan.sourceRect.minY
        )

        do {
            let image = try await capturer.capture(rect: target.frame)
            let currentTarget = WindowTargeting.frontmostWindow()
            guard WindowTargeting.canCompleteCapture(
                requiresSession: requiresSession, isCapturing: isCapturing,
                current: currentTarget, snapshot: target, session: captureSession
            ) else {
                HUD.shared.show("Window changed or capture cancelled — ink kept")
                return
            }
            let prepared = settings.paperTone ? PaperTone.apply(to: image) : image
            let composited = compositeInk(onto: prepared, origin: captureOrigin, scale: display.scale)
                .flattened()
            let png = composited.pngData()
            if clipboard, !self.clipboard.writeNow(image: composited, png: png) {
                HUD.shared.show("Clipboard write failed — ink kept")
                return
            }
            var saved = false
            if save, let png {
                saved = history.save(png) != nil
            }

            if paste && clipboard {
                let ownBundleID = Bundle.main.bundleIdentifier
                let applicationID = WindowTargeting.deliveryApplication(
                    preference: settings.pasteTarget,
                    previous: previousApplicationID,
                    frontmost: target.bundleIdentifier,
                    pinned: settings.pasteOverrideAppID,
                    own: ownBundleID
                )
                let expectedPID: pid_t?
                if settings.pasteOverrideAppID != nil {
                    expectedPID = nil // A pinned choice identifies an application, not one instance.
                } else {
                    expectedPID = settings.pasteTarget == .previousApp ? previousApplicationPID : target.identity.processID
                }
                let pasted = await paster.paste(into: applicationID, expectedProcessID: expectedPID)
                let message = pasted ? "Copied to clipboard — paste sent" : "Copied to clipboard (paste failed)"
                HUD.shared.show(save && !saved ? message + " — save failed" : message)
            } else if clipboard {
                HUD.shared.show(save && !saved ? "Copied to clipboard — save failed" : "Copied to clipboard")
            } else {
                HUD.shared.show(saved ? "Saved" : "Save failed — ink kept")
            }
        } catch {
            Diagnostics.log("Copy & paste failed: \(error.localizedDescription)")
            HUD.shared.show("Capture failed")
        }

        // The ink is kept on purpose: the next annotation session continues on
        // top of it, and barrel 2 / the menu clear it.
    }

    // MARK: Editing

    func undo() {
        guard !isRendering else { return }
        canvas.undo()
        overlay.discardContact()
        overlay.refresh()
        refreshState()
    }

    func clear() {
        guard !isRendering else { return }
        canvas.clear()
        overlay.discardContact()
        overlay.refresh()
        refreshState()
    }

    // MARK: Helpers

    /// Clip and composite exactly the strokes in the window's frame, leaving
    /// the canvas (which spans the whole union frame) untouched so the ink
    /// survives the copy and the next session keeps annotating on top.
    private func compositeInk(onto image: ImageBuffer, origin: Point, scale: Double) -> ImageBuffer {
        var style = StrokeStyle.standard
        style.fixedWidth *= scale
        style.minWidth *= scale
        style.maxWidth *= scale

        let strokes = canvas.allStrokes().map { stroke in
            Stroke(
                ink: stroke.ink,
                points: stroke.points.map { point in
                    StrokePoint(
                        location: Point(
                            x: (point.location.x - origin.x) * scale,
                            y: (point.location.y - origin.y) * scale
                        ),
                        pressure: point.pressure,
                        isTablet: point.isTablet
                    )
                }
            )
        }
        return BufferInkCompositor().composite(strokes: strokes, style: style, onto: image)
    }

    @discardableResult
    private func applyHotkey(_ hotkey: Hotkey) -> Bool {
        hotkeys.unregister()
        let registered = hotkeys.register(hotkey)
        if registered {
            activeHotkey = hotkey
            hotkeyRegistered = true
        } else {
            hotkeyRegistered = false
            Diagnostics.log("Could not register \(hotkey.displayString); it may be in use")
            // Revert the stored preference so the UI doesn't show a hotkey that
            // is not actually bound; this re-triggers applyHotkey via the sink.
            if let previous = activeHotkey, previous != hotkey {
                settings.hotkey = previous
            }
        }
        return registered
    }

    private func refreshState() {
        strokeCount = canvas.strokeCount
        hasInk = canvas.hasContent
    }
}

import AppKit
import Combine
import PalimpsestCore

/// Owns the status bar item and builds its menu with AppKit directly so the
/// content (labels, checkmarks, window list) is rebuilt fresh every time the
/// menu opens and titles update live while it is visible.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private unowned let controller: AppController
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private var pasteHeader: NSMenuItem?
    private var colourHeader: NSMenuItem?
    private var toggleItem: NSMenuItem?
    private var clearItem: NSMenuItem?
    private var cancellables = Set<AnyCancellable>()

    init(controller: AppController) {
        self.controller = controller
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "scribble.variable",
            accessibilityDescription: "ScribbleEverywhere"
        )
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        rebuild()

        controller.settings.$pasteTarget
            .combineLatest(controller.settings.$pasteOverrideAppID, controller.settings.$pasteOverrideAppName)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.pasteHeader?.title = self?.pasteTitle() ?? "" }
            .store(in: &cancellables)

        controller.settings.$palette
            .combineLatest(controller.settings.$colourNames)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateColourTitle() }
            .store(in: &cancellables)

        controller.$isCapturing
            .combineLatest(controller.$hasInk)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateToggleTitle() }
            .store(in: &cancellables)

        controller.settings.$action
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateToggleTitle() }
            .store(in: &cancellables)
    }

    // MARK: - Menu construction

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    private func rebuild() {
        let settings = controller.settings
        menu.removeAllItems()
        pasteHeader = nil
        colourHeader = nil

        let toggle = NSMenuItem(
            title: stopLabel,
            action: #selector(toggleCapture(_:)),
            keyEquivalent: "\r"
        )
        toggle.target = self
        toggleItem = toggle
        menu.addItem(toggle)

        let colourMenu = NSMenu()
        colourMenu.autoenablesItems = false
        for (index, colour) in settings.palette.colors.enumerated() {
            let item = NSMenuItem(
                title: settings.displayName(for: colour),
                action: #selector(chooseColour(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = index
            if index == settings.palette.index {
                item.state = .on
            } else {
                item.image = NSImage.swatch(colour)
            }
            colourMenu.addItem(item)
        }
        let colour = NSMenuItem(
            title: "Ink Colour (\(settings.displayName(for: settings.palette.current)))",
            action: nil,
            keyEquivalent: ""
        )
        colour.submenu = colourMenu
        colourHeader = colour
        menu.addItem(colour)

        let actionMenu = NSMenu()
        actionMenu.autoenablesItems = false
        for action in DeliveryAction.allCases {
            let item = NSMenuItem(title: action.title, action: #selector(selectAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            item.state = settings.action == action ? .on : .off
            actionMenu.addItem(item)
        }
        let action = NSMenuItem(title: "On stop", action: nil, keyEquivalent: "")
        action.submenu = actionMenu
        menu.addItem(action)
        menu.addItem(pasteMenu())

        let files = controller.history.files
        do {
            let historyMenu = NSMenu()
            historyMenu.autoenablesItems = false
            if files.isEmpty {
                let none = NSMenuItem(title: "No saved annotations", action: nil, keyEquivalent: "")
                none.isEnabled = false
                historyMenu.addItem(none)
            }
            for file in files.prefix(10) {
                let item = NSMenuItem(
                    title: file.deletingPathExtension().lastPathComponent,
                    action: #selector(revealAnnotation(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = file
                historyMenu.addItem(item)
            }
            historyMenu.addItem(.separator())
            let openFolder = NSMenuItem(
                title: "Open Annotations Folder",
                action: #selector(openAnnotationsFolder(_:)),
                keyEquivalent: ""
            )
            openFolder.target = self
            historyMenu.addItem(openFolder)
            let history = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
            history.submenu = historyMenu
            menu.addItem(history)
        }

        let clear = NSMenuItem(
            title: "Clear",
            action: controller.hasInk ? #selector(clearInk(_:)) : nil,
            keyEquivalent: ""
        )
        clear.target = self
        clearItem = clear
        menu.addItem(clear)

        menu.addItem(.separator())

        let hotkey = NSMenuItem(title: controller.hotkeyDisplay, action: nil, keyEquivalent: "")
        hotkey.isEnabled = false
        menu.addItem(hotkey)
        if !controller.hotkeyRegistered {
            let warning = NSMenuItem(title: "⚠︎ Hotkey unavailable", action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let permissions = NSMenuItem(
            title: "Check Permissions",
            action: #selector(checkPermissions(_:)),
            keyEquivalent: ""
        )
        permissions.target = self
        menu.addItem(permissions)

        let about = NSMenuItem(title: "About ScribbleEverywhere", action: nil, keyEquivalent: "")
        let aboutMenu = NSMenu()
        aboutMenu.autoenablesItems = false
        let readme = NSMenuItem(
            title: "Readme & Star ★",
            action: #selector(openRepository(_:)),
            keyEquivalent: ""
        )
        readme.target = self
        aboutMenu.addItem(readme)
        let issues = NSMenuItem(
            title: "Report an Issue / Feedback",
            action: #selector(openIssues(_:)),
            keyEquivalent: ""
        )
        issues.target = self
        aboutMenu.addItem(issues)
        about.submenu = aboutMenu
        menu.addItem(about)

        let quit = NSMenuItem(
            title: "Quit ScribbleEverywhere",
            action: #selector(quit(_:)),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
    }

    private func pasteMenu() -> NSMenuItem {
        let settings = controller.settings
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let previous = NSMenuItem(
            title: "Previous window",
            action: #selector(pastePrevious(_:)),
            keyEquivalent: ""
        )
        previous.target = self
        if settings.pasteOverrideAppID == nil && settings.pasteTarget == .previousApp {
            previous.state = .on
        }
        submenu.addItem(previous)

        let frontmost = NSMenuItem(
            title: "Frontmost window",
            action: #selector(pasteFrontmost(_:)),
            keyEquivalent: ""
        )
        frontmost.target = self
        if settings.pasteOverrideAppID == nil && settings.pasteTarget == .frontmostApp {
            frontmost.state = .on
        }
        submenu.addItem(frontmost)

        submenu.addItem(.separator())

        let windows = WindowTargeting.visibleWindows()
        if windows.isEmpty {
            let none = NSMenuItem(title: "No other windows running", action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        }
        for window in windows {
            guard let bundleID = window.bundleIdentifier else { continue }
            let item = NSMenuItem(
                title: window.applicationName ?? bundleID,
                action: #selector(pasteApp(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = bundleID
            if settings.pasteOverrideAppID == bundleID {
                item.state = .on
            }
            submenu.addItem(item)
        }

        let header = NSMenuItem(title: pasteTitle(), action: nil, keyEquivalent: "")
        header.submenu = submenu
        pasteHeader = header
        return header
    }

    // MARK: - Titles

    private func pasteTitle() -> String {
        let settings = controller.settings
        if settings.pasteOverrideAppID != nil, let name = settings.pasteOverrideAppName {
            return "Paste into (\(name))"
        }
        let preference = settings.pasteTarget == .previousApp ? "Previous window" : "Frontmost window"
        return "Paste into (\(preference))"
    }

    private var stopLabel: String {
        guard controller.isCapturing else { return "Start Annotating" }
        guard controller.hasInk else { return "Stop Annotating" }
        return controller.settings.action == .copyAndPaste ? "Stop & Paste" : "Stop & Copy"
    }

    private func updateColourTitle() {
        colourHeader?.title = "Ink Colour (\(controller.settings.displayName(for: controller.settings.palette.current)))"
    }

    private func updateToggleTitle() {
        toggleItem?.title = stopLabel
        clearItem?.isEnabled = controller.hasInk
        clearItem?.action = controller.hasInk ? #selector(clearInk(_:)) : nil
    }

    // MARK: - Actions

    @objc private func toggleCapture(_ sender: NSMenuItem) {
        controller.toggleCaptureMode()
    }

    @objc private func selectAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = DeliveryAction(rawValue: raw) else { return }
        controller.settings.action = action
        updateToggleTitle()
    }

    @objc private func chooseColour(_ sender: NSMenuItem) {
        let index = sender.tag
        controller.settings.selectColour(at: index)
        HUD.shared.show("Ink: \(controller.settings.displayName(for: controller.settings.palette.current))")
    }

    @objc private func pastePrevious(_ sender: NSMenuItem) {
        controller.settings.pasteOverrideAppID = nil
        controller.settings.pasteOverrideAppName = nil
        controller.settings.pasteTarget = .previousApp
    }

    @objc private func pasteFrontmost(_ sender: NSMenuItem) {
        controller.settings.pasteOverrideAppID = nil
        controller.settings.pasteOverrideAppName = nil
        controller.settings.pasteTarget = .frontmostApp
    }

    @objc private func pasteApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        controller.settings.pasteOverrideAppID = bundleID
        controller.settings.pasteOverrideAppName = sender.title
    }

    @objc private func revealAnnotation(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? URL else { return }
        controller.history.reveal(file)
    }

    @objc private func openAnnotationsFolder(_ sender: NSMenuItem) {
        controller.history.openFolder()
    }

    @objc private func clearInk(_ sender: NSMenuItem) {
        controller.clear()
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func checkPermissions(_ sender: NSMenuItem) {
        controller.checkPermissions()
    }

    @objc private func openRepository(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(URL(string: "https://github.com/matthewhand/scribble-everywhere")!)
    }

    @objc private func openIssues(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(URL(string: "https://github.com/matthewhand/scribble-everywhere/issues")!)
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}

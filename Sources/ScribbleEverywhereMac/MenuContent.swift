import SwiftUI
import PalimpsestCore

struct MenuContent: View {
    @ObservedObject var controller: AppController
    @ObservedObject var settings: SettingsStore

    init(controller: AppController) {
        self.controller = controller
        self.settings = controller.settings
    }

    var body: some View {
        Button(stopLabel) {
            controller.toggleCaptureMode()
        }
        .keyboardShortcut(.defaultAction)

        Menu("Ink Colour (\(settings.displayName(for: settings.palette.current)))") {
            ForEach(Array(settings.palette.colors.enumerated()), id: \.offset) { index, color in
                Button {
                    settings.selectColour(at: index)
                    HUD.shared.show("Ink: \(settings.displayName(for: color))")
                } label: {
                    Label {
                        Text(settings.displayName(for: color))
                    } icon: {
                        if index == settings.palette.index {
                            Image(systemName: "checkmark")
                        } else {
                            Image(nsImage: .swatch(color))
                        }
                    }
                }
            }
        }

        Menu("On stop") {
            ForEach(DeliveryAction.allCases, id: \.self) { action in
                Button {
                    settings.action = action
                } label: {
                    Label(action.title, systemImage: settings.action == action ? "checkmark" : "circle")
                }
            }
        }
        PasteTargetMenu(controller: controller)

        Menu("History") {
            if controller.history.files.isEmpty {
                Text("No saved annotations")
            }
            ForEach(controller.history.files.prefix(10), id: \.self) { file in
                Button(file.deletingPathExtension().lastPathComponent) {
                    controller.history.reveal(file)
                }
            }

            Divider()

            Button("Open Annotations Folder") {
                controller.history.openFolder()
            }
        }

        Button("Clear") {
            controller.clear()
        }
        .disabled(!controller.hasInk)

        Divider()

        Text(controller.hotkeyDisplay)
        if !controller.hotkeyRegistered {
            Text("⚠︎ Hotkey unavailable")
        }

        Divider()

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("Check Permissions") {
            controller.checkPermissions()
        }

        Menu("About ScribbleEverywhere") {
            Button("Readme & Star ★") {
                open(Links.repository)
            }
            Button("Report an Issue / Feedback") {
                open(Links.issues)
            }
        }

        Button("Quit ScribbleEverywhere") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private enum Links {
        static let repository = URL(string: "https://github.com/matthewhand/scribble-everywhere")!
        static let issues = URL(string: "https://github.com/matthewhand/scribble-everywhere/issues")!
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private var stopLabel: String {
        guard controller.isCapturing else { return "Start Annotating" }
        guard controller.hasInk else { return "Stop Annotating" }
        return settings.action == .copyAndPaste ? "Stop & Paste" : "Stop & Copy"
    }
}

/// "Paste into" submenu: previous window, frontmost window, or pin a
/// specific running app. The top-level label always shows the resolved
/// target, so every choice is visible without reopening the submenu.
struct PasteTargetMenu: View {
    @ObservedObject var controller: AppController

    /// Re-evaluated whenever the menu opens, so the list is live.
    private var windows: [WindowTarget] {
        WindowTargeting.visibleWindows()
    }

    var body: some View {
        Menu(pasteTitle) {
            Button {
                controller.settings.pasteOverrideAppID = nil
                controller.settings.pasteOverrideAppName = nil
                controller.settings.pasteTarget = .previousApp
            } label: {
                choiceLabel("Previous window", checked: isUnpinned && controller.settings.pasteTarget == .previousApp)
            }

            Button {
                controller.settings.pasteOverrideAppID = nil
                controller.settings.pasteOverrideAppName = nil
                controller.settings.pasteTarget = .frontmostApp
            } label: {
                choiceLabel("Frontmost window", checked: isUnpinned && controller.settings.pasteTarget == .frontmostApp)
            }

            Divider()

            if windows.isEmpty {
                Text("No other windows running")
                    .foregroundStyle(.secondary)
            }
            ForEach(windows, id: \.bundleIdentifier) { window in
                if let bundleID = window.bundleIdentifier {
                    Button {
                        controller.settings.pasteOverrideAppID = bundleID
                        controller.settings.pasteOverrideAppName = window.applicationName ?? bundleID
                    } label: {
                        choiceLabel(
                            window.applicationName ?? bundleID,
                            checked: controller.settings.pasteOverrideAppID == bundleID
                        )
                    }
                }
            }
        }
    }

    private var isUnpinned: Bool {
        controller.settings.pasteOverrideAppID == nil
    }

    private var pasteTitle: String {
        if let name = controller.settings.pasteOverrideAppName, controller.settings.pasteOverrideAppID != nil {
            return "Paste into (\(name))"
        }
        let preference = controller.settings.pasteTarget == .previousApp ? "Previous window" : "Frontmost window"
        return "Paste into (\(preference))"
    }

    private func choiceLabel(_ title: String, checked: Bool) -> some View {
        Label {
            Text(title)
        } icon: {
            if checked {
                Image(systemName: "checkmark")
            }
        }
    }
}

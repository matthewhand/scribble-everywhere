import SwiftUI
import PalimpsestCore

@main
struct PalimpsestInkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = AppController.shared

    var body: some Scene {
        Settings {
            SettingsView(store: controller.settings)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class StatusMenuBox: ObservableObject {
    let controller: StatusMenuController

    init(controller: AppController) {
        self.controller = StatusMenuController(controller: controller)
    }
}

import AppKit
import PalimpsestCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var statusMenu: StatusMenuBox?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusMenu = StatusMenuBox(controller: AppController.shared)
        AppController.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppController.shared.stop()
    }
}

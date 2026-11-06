import Foundation

enum Diagnostics {
    static func log(_ message: String) {
        NSLog("[PalimpsestInk] %@", message)
    }
}

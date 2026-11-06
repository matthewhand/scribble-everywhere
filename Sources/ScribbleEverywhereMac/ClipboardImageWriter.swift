import AppKit
import PalimpsestCore

final class ClipboardImageWriter: PalimpsestCore.ClipboardWriter {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    func write(image: ImageBuffer, png: Data?) {
        _ = writeNow(image: image, png: png)
    }

    @discardableResult
    func writeNow(image: ImageBuffer, png: Data?) -> Bool {
        if let png {
            pasteboard.clearContents()
            return pasteboard.setData(png, forType: .png)
        } else if let cgImage = image.cgImage() {
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: image.width, height: image.height))
            pasteboard.clearContents()
            return pasteboard.writeObjects([nsImage])
        }
        return false
    }
}

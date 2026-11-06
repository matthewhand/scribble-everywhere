import AppKit
import Foundation

@MainActor
final class AnnotationHistory: ObservableObject {
    @Published private(set) var files: [URL] = []

    private(set) var folder: URL
    private let now: () -> Date

    init(folder: URL, now: @escaping () -> Date = Date.init) {
        self.folder = folder
        self.now = now
        refresh()
    }

    func setFolder(_ folder: URL) {
        self.folder = folder
        refresh()
    }

    func save(_ png: Data) -> URL? {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            // Timestamps have millisecond precision; two exports in the same
            // millisecond must not replace the earlier annotation.
            let timestamp = formatter.string(from: now()).replacingOccurrences(of: ":", with: "-")
            let name = "Annotation \(timestamp) \(UUID().uuidString).png"
            let url = folder.appendingPathComponent(name)
            try png.write(to: url, options: .atomic)
            refresh()
            return url
        } catch {
            Diagnostics.log("Could not save annotation: \(error.localizedDescription)")
            return nil
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openFolder() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if !NSWorkspace.shared.open(folder) { HUD.shared.show("Could not open annotations folder") }
        } catch {
            Diagnostics.log("Could not open annotations folder: \(error.localizedDescription)")
            HUD.shared.show("Could not open annotations folder")
        }
    }

    func refresh() {
        files = ((try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.pathExtension.lowercased() == "png" }.sorted {
            ($0.contentModificationDate ?? .distantPast) > ($1.contentModificationDate ?? .distantPast)
        }
    }
}

private extension URL {
    var contentModificationDate: Date? {
        try? resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

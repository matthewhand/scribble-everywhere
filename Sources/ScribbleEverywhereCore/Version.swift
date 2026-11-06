import Foundation

/// The one place the app version is written down. The shells print it so a bug
/// report can say which build is installed, and `scripts/check-version.sh`
/// keeps `Info.plist` and `README.md` in agreement with this value.
public enum PalimpsestVersion {
    /// `major.minor.patch`, matching `CFBundleShortVersionString`.
    public static let short = "0.1.0"

    /// `ScribbleEverywhere <short>` — what `palimpsestctl version` and the macOS
    /// About line show.
    public static var displayString: String { "ScribbleEverywhere \(short)" }
}

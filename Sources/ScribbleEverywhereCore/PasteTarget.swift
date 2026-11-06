import Foundation

public enum PasteTargetPreference: String, Equatable, Sendable {
    case previousApp
    case frontmostApp
}

public enum PasteTarget {
    /// Chooses which application should receive the paste. Falls back to the
    /// other candidate when the preferred one is unavailable (e.g. it quit).
    /// `overrideApp` (a pinned window picked in the applet) always wins when
    /// set, regardless of the preference.
    ///
    /// `excluding` is our own bundle identifier. Candidates equal to it are
    /// dropped before the preference is applied: pasting into ourselves would
    /// reactivate the applet and post ⌘V into the overlay, so the paste would
    /// silently go nowhere. This can happen because the pinned override, or a
    /// previous-app capture raced while the applet was frontmost.
    public static func choose(
        preference: PasteTargetPreference,
        previousApp: String?,
        frontmostApp: String?,
        overrideApp: String? = nil,
        excluding ownApp: String? = nil
    ) -> String? {
        func usable(_ id: String?) -> String? {
            guard let id, !id.isEmpty, id != ownApp else { return nil }
            return id
        }

        if let override = usable(overrideApp) {
            return override
        }
        let previous = usable(previousApp)
        let frontmost = usable(frontmostApp)
        switch preference {
        case .previousApp:
            return previous ?? frontmost
        case .frontmostApp:
            return frontmost ?? previous
        }
    }
}

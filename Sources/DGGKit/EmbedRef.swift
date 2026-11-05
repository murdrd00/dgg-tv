import Foundation

/// An embed as chatters write it: "#twitch/zackrawrr", "#kick/xqc",
/// "#youtube/A4gNgHfZ-v4", "#kick-vod/Destiny/8202a0b4-...".
public struct EmbedRef: Hashable, Sendable, Identifiable {

    public enum Platform: String, Sendable, CaseIterable {
        case twitch, kick, youtube, rumble, vimeo

        /// Can the tvOS app get a playable stream for this on its own?
        public var resolvableOnDevice: Bool {
            switch self {
            case .twitch: return true          // GQL + usher, two plain HTTPS calls
            case .kick:   return true          // public API, but Cloudflare may refuse
            case .youtube, .rumble, .vimeo:
                return false                   // needs JS extraction
            }
        }
    }

    public let platform: Platform
    /// Channel login, video id, or "channel/uuid" for VODs.
    public let path: String
    public let isVOD: Bool

    public var id: String { token }

    /// Live streams from a platform we can resolve. VODs aren't supported.
    public var playsInApp: Bool { platform.resolvableOnDevice && !isVOD }

    /// The platform's own app, if we know how to send a stream to it.
    public var nativeApp: (name: String, url: URL)? {
        guard !isVOD else { return nil }
        switch platform {
        case .youtube: return youTubeAppURL.map { ("YouTube", $0) }
        case .twitch:  return URL(string: "twitch://stream/\(path)").map { ("Twitch", $0) }
        // Its tvOS app answers to `kicktv`, but no link tried reaches a channel:
        // this only opens the app, which is why the menu says "Open".
        case .kick:    return URL(string: "kicktv://").map { ("Kick", $0) }
        default:       return nil
        }
    }

    /// The video's cover image, best first: not every video has the large one.
    public var youTubeThumbnailURLs: [URL] {
        guard youTubeAppURL != nil else { return [] }
        return ["maxresdefault_live", "hqdefault_live"].compactMap {
            URL(string: "https://i.ytimg.com/vi/\(path)/\($0).jpg")
        }
    }

    /// Where this opens instead, for YouTube: its own app takes this link.
    public var youTubeAppURL: URL? {
        guard platform == .youtube, !isVOD else { return nil }
        return URL(string: "youtube://www.youtube.com/watch?v=\(path)")
    }

    public var token: String {
        "#\(platform.rawValue)\(isVOD ? "-vod" : "")/\(path)"
    }

    /// Human label for the UI row.
    public var displayName: String {
        isVOD ? "\(path.split(separator: "/").first.map(String.init) ?? path) (VOD)" : path
    }

    public init(platform: Platform, path: String, isVOD: Bool = false) {
        self.platform = platform
        self.path = path
        self.isVOD = isVOD
    }

    // MARK: - Scanning chat text

    private static let pattern = try! NSRegularExpression(
        pattern: "#(twitch|kick|youtube|rumble|vimeo)(-vod)?/([A-Za-z0-9_\\-]+(?:/[A-Za-z0-9_\\-]+)?)",
        options: [.caseInsensitive]
    )

    /// Pulls every embed reference out of a chat line, in order.
    public static func scan(_ text: String) -> [EmbedRef] {
        let ns = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { m in
            guard m.numberOfRanges >= 4,
                  let p = Platform(rawValue: ns.substring(with: m.range(at: 1)).lowercased())
            else { return nil }
            let vod = m.range(at: 2).location != NSNotFound
            let raw = ns.substring(with: m.range(at: 3))
            guard !raw.isEmpty else { return nil }
            // Twitch logins and Kick slugs are case-insensitive, so fold them
            // to keep "#twitch/Emiru" and "#twitch/emiru" as one entry.
            // YouTube/Rumble/Vimeo ids ARE case-sensitive — never fold those.
            let foldable = !vod && (p == .twitch || p == .kick)
            return EmbedRef(platform: p, path: foldable ? raw.lowercased() : raw, isVOD: vod)
        }
    }
}

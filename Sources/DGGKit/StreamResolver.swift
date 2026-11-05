import Foundation

public enum ResolveError: LocalizedError {
    case unsupported(EmbedRef.Platform)
    case blocked(String)
    case badResponse(String)
    case offline

    public var errorDescription: String? {
        switch self {
        case .unsupported(let p): return "\(p.rawValue.capitalized) can't play in this app"
        case .blocked(let s):     return "blocked: \(s)"
        case .badResponse(let s): return "unexpected response: \(s)"
        case .offline:            return "channel is offline"
        }
    }
}

/// Turns an EmbedRef into an HLS URL that AVPlayer can open directly.
public struct StreamResolver: Sendable {

    public init() {}

    public func resolve(_ ref: EmbedRef) async throws -> URL {
        switch ref.platform {
        case .twitch where !ref.isVOD:
            return try await TwitchResolver.masterPlaylist(channel: ref.path)
        case .kick where !ref.isVOD:
            return try await KickResolver.playbackURL(channel: ref.path)
        default:
            throw ResolveError.unsupported(ref.platform)
        }
    }
}

public extension StreamResolver {
    /// Cheap check for the embed list. Fields left nil are unknown, so callers
    /// should keep what they have and should NOT hide an embed on nil.
    func status(_ ref: EmbedRef) async -> StreamStatus {
        guard !ref.isVOD else { return StreamStatus() }
        do {
            switch ref.platform {
            case .twitch:
                _ = try await TwitchResolver.accessToken(channel: ref.path)
                return StreamStatus(live: true,
                                    title: await TwitchResolver.title(channel: ref.path))
            case .kick:
                let channel = try await KickResolver.liveChannel(ref.path)
                return StreamStatus(live: true, title: channel.livestream?.session_title)
            case .youtube:
                switch await YouTubeInfo.lookUp(videoID: ref.path) {
                case .found(let channel, let title):
                    return StreamStatus(title: title, channel: channel)
                case .refused:
                    // Private and removed videos are refused here, but so are
                    // ones that merely disable embedding, so check the page.
                    let page = await YouTubeInfo.pageState(videoID: ref.path)
                    return StreamStatus(unavailable: page == .unavailable)
                case .unreachable:
                    return StreamStatus()
                }
            default:
                return StreamStatus()
            }
        } catch ResolveError.offline {
            return StreamStatus(live: false)
        } catch {
            return StreamStatus()   // network/blocked — don't claim it's offline
        }
    }
}

public struct StreamStatus: Sendable {
    public var live: Bool?
    public var title: String?
    /// YouTube only: embeds arrive as a bare video id.
    public var channel: String?
    /// Private or removed, so it can never be watched.
    public var unavailable = false

    public init(live: Bool? = nil, title: String? = nil, channel: String? = nil,
                unavailable: Bool = false) {
        self.live = live
        self.title = title
        self.channel = channel
        self.unavailable = unavailable
    }
}

// MARK: - Twitch: no SDK, but no JS either. Two calls.

public enum TwitchResolver {

    /// Public web client id, same one twitch.tv itself ships.
    static let clientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"
    static let persistedQueryHash =
        "0828119ded1c13477966434e15800ff57ddacf13ba1911c129dc2200705b0712"

    struct TokenResponse: Decodable {
        struct DataBlock: Decodable {
            struct Token: Decodable { let value: String; let signature: String }
            let streamPlaybackAccessToken: Token?
        }
        let data: DataBlock?
    }

    public static func accessToken(channel: String) async throws -> (value: String, sig: String) {
        var req = URLRequest(url: URL(string: "https://gql.twitch.tv/gql")!)
        req.httpMethod = "POST"
        req.setValue(clientID, forHTTPHeaderField: "Client-Id")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "operationName": "PlaybackAccessToken",
            "variables": [
                "isLive": true, "login": channel,
                "isVod": false, "vodID": "", "playerType": "site",
            ],
            "extensions": ["persistedQuery": ["version": 1,
                                              "sha256Hash": persistedQueryHash]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ResolveError.blocked("gql http \(code)") }
        guard let parsed = try? JSONDecoder().decode(TokenResponse.self, from: data),
              let tok = parsed.data?.streamPlaybackAccessToken
        else { throw ResolveError.offline }
        return (tok.value, tok.signature)
    }

    private struct TitleResponse: Decodable {
        struct DataBlock: Decodable {
            struct User: Decodable {
                struct Settings: Decodable { let title: String? }
                let broadcastSettings: Settings?
            }
            let user: User?
        }
        let data: DataBlock?
    }

    static func title(channel: String) async -> String? {
        var req = URLRequest(url: URL(string: "https://gql.twitch.tv/gql")!)
        req.httpMethod = "POST"
        req.setValue(clientID, forHTTPHeaderField: "Client-Id")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "query": "query($l:String!){user(login:$l){broadcastSettings{title}}}",
            "variables": ["l": channel],
        ]
        guard let http = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = http
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let parsed = try? JSONDecoder().decode(TitleResponse.self, from: data)
        else { return nil }
        return parsed.data?.user?.broadcastSettings?.title
    }

    /// Returns the MASTER playlist so AVPlayer does its own bitrate adaptation.
    public static func masterPlaylist(channel: String) async throws -> URL {
        let t = try await accessToken(channel: channel)
        var c = URLComponents(string: "https://usher.ttvnw.net/api/channel/hls/\(channel).m3u8")!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "token", value: t.value),
            .init(name: "sig", value: t.sig),
            .init(name: "allow_source", value: "true"),
            .init(name: "allow_audio_only", value: "true"),
            .init(name: "player", value: "twitchweb"),
            .init(name: "playlist_include_framerate", value: "true"),
            .init(name: "fast_bread", value: "true"),
        ]
        guard let u = c.url else { throw ResolveError.badResponse("usher url") }
        return u
    }
}

// MARK: - Kick: public API, but Cloudflare sits in front of it.

public enum KickResolver {

    struct Channel: Decodable {
        struct Livestream: Decodable {
            let is_live: Bool?
            let session_title: String?
        }
        let playback_url: String?
        let livestream: Livestream?
    }

    public static func playbackURL(channel: String) async throws -> URL {
        let ch = try await liveChannel(channel)
        guard let s = ch.playback_url, let u = URL(string: s) else { throw ResolveError.offline }
        return u
    }

    /// Throws `.offline` unless the channel is live.
    static func liveChannel(_ channel: String) async throws -> Channel {
        var req = URLRequest(url: URL(string: "https://kick.com/api/v2/channels/\(channel)")!)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                     + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ResolveError.blocked("kick http \(code) (Cloudflare)") }
        guard let ch = try? JSONDecoder().decode(Channel.self, from: data) else {
            throw ResolveError.badResponse("kick json")
        }
        // Kick returns a playback_url even for an OFFLINE channel; fetching it
        // then 404s and the app shows a silent black screen. Check is_live.
        guard ch.livestream?.is_live == true else { throw ResolveError.offline }
        return ch
    }
}

/// What YouTube will say about a video without an API key.
public enum YouTubeInfo {
    private struct OEmbed: Decodable {
        let author_name: String
        let title: String
    }

    public enum LookUp: Sendable {
        case found(channel: String, title: String)
        /// YouTube answered and said no.
        case refused
        case unreachable
    }

    public static func lookUp(videoID: String) async -> LookUp {
        var c = URLComponents(string: "https://www.youtube.com/oembed")!
        c.queryItems = [
            URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(videoID)"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = c.url,
              let (data, resp) = try? await URLSession.shared.data(from: url),
              let code = (resp as? HTTPURLResponse)?.statusCode
        else { return .unreachable }
        guard code == 200 else { return (400..<500).contains(code) ? .refused : .unreachable }
        guard let info = try? JSONDecoder().decode(OEmbed.self, from: data) else {
            return .unreachable
        }
        return .found(channel: info.author_name, title: info.title)
    }

    public enum PageState: Sendable {
        case live
        /// A finished stream or an ordinary video: watchable, not live.
        case notLive
        case unavailable
        case unknown
    }

    /// Reads the watch page, the only keyless place that says whether a video
    /// is live. It's over a megabyte, so only use it when the answer matters.
    public static func pageState(videoID: String) async -> PageState {
        guard let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)") else {
            return .unknown
        }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                     + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("en", forHTTPHeaderField: "Accept-Language")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return .unknown }
        func has(_ s: String) -> Bool { data.range(of: Data(s.utf8)) != nil }
        guard has("\"playabilityStatus\"") else { return .unknown }
        guard has("\"playabilityStatus\":{\"status\":\"OK\"") else { return .unavailable }
        return has("\"isLiveNow\":true") ? .live : .notLive
    }
}

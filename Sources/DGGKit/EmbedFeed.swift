import Foundation

/// The site's own embed list, from the feed its Big Screen page uses. It arrives
/// complete, with names, titles and live status, and already free of banned or
/// dead embeds. Working the same thing out from chat is what `EmbedTracker` does,
/// and that's now only the fallback for when this can't be reached.
public final class EmbedFeed: @unchecked Sendable {

    public struct Item: Sendable {
        public let ref: EmbedRef
        /// People on destiny.gg watching it, not the stream's whole audience.
        public let watching: Int
        public let name: String?
        public let title: String?
        public let live: Bool?
        /// A still from the stream, where the site has one.
        public let preview: URL?
    }

    private static let endpoint = URL(string: "wss://live.destiny.gg")!

    private struct Envelope: Decodable {
        struct Entry: Decodable {
            struct Media: Decodable {
                struct Metadata: Decodable {
                    let displayName: String?
                    let title: String?
                    let live: Bool?
                    let previewUrl: String?
                }
                let metadata: Metadata?
            }
            let platform: String
            let id: String
            let count: Int?
            let mediaItem: Media?
        }
        let data: [Lenient]
    }

    /// One odd entry shouldn't cost the whole list.
    private struct Lenient: Decodable {
        let entry: Envelope.Entry?
        init(from decoder: Decoder) throws { entry = try? Envelope.Entry(from: decoder) }
    }

    /// What else the feed says that changes what to watch.
    public enum Update: Sendable {
        case embeds([Item])
        /// What the mods are hosting, nil for nothing.
        case hosting(EmbedRef?)
        /// Destiny's own streams that are live right now.
        case destinyLive([EmbedRef])
    }

    public init() {}

    /// The list once, for something that can't stay connected, like Top Shelf.
    /// Nil if it doesn't arrive in time.
    public static func snapshot(timeout: Duration = .seconds(8)) async -> [Item]? {
        await withTaskGroup(of: [Item]?.self) { group in
            group.addTask {
                let socket = URLSession.shared.webSocketTask(with: endpoint)
                socket.maximumMessageSize = 8 * 1024 * 1024
                socket.resume()
                defer { socket.cancel(with: .goingAway, reason: nil) }
                while !Task.isCancelled {
                    guard let message = try? await socket.receive() else { return nil }
                    let text: String?
                    switch message {
                    case .string(let s): text = s
                    case .data(let d):   text = String(data: d, encoding: .utf8)
                    @unknown default:    text = nil
                    }
                    if let text, let items = parse(text) { return items }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Every list the site publishes, reconnecting for as long as it's listened to.
    public func updates() -> AsyncStream<Update> {
        AsyncStream { continuation in
            let run = Task {
                var wait = 2.0
                while !Task.isCancelled {
                    await Self.listen(continuation) { wait = 2 }
                    try? await Task.sleep(for: .seconds(wait))
                    wait = min(wait * 2, 30)
                }
            }
            continuation.onTermination = { _ in run.cancel() }
        }
    }

    private static func listen(_ out: AsyncStream<Update>.Continuation,
                               connected: () -> Void) async {
        let socket = URLSession.shared.webSocketTask(with: endpoint)
        socket.maximumMessageSize = 8 * 1024 * 1024
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }

        let keepAlive = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                // A socket can die without a word, most often while the app was
                // in the background, and the list would then never change again.
                // A ping that fails ends it, so the loop above connects afresh.
                socket.sendPing { error in
                    if error != nil { socket.cancel(with: .goingAway, reason: nil) }
                }
            }
        }
        defer { keepAlive.cancel() }

        while !Task.isCancelled {
            guard let message = try? await socket.receive() else { return }
            connected()
            let text: String?
            switch message {
            case .string(let s): text = s
            case .data(let d):   text = String(data: d, encoding: .utf8)
            @unknown default:    text = nil
            }
            guard let text else { continue }
            if let items = parse(text) { out.yield(.embeds(items)) }
            else if let host = hosting(text) { out.yield(.hosting(host.ref)) }
            else if let live = destinyLive(text) { out.yield(.destinyLive(live)) }
        }
    }

    private static func ref(platform: String, id: String) -> EmbedRef? {
        guard let p = EmbedRef.Platform(rawValue: platform.lowercased()), !id.isEmpty else { return nil }
        let folded = p == .twitch || p == .kick
        return EmbedRef(platform: p, path: folded ? id.lowercased() : id)
    }

    private struct HostEnvelope: Decodable {
        struct Host: Decodable { let platform: String?; let id: String? }
        let data: Host?
    }

    /// Wrapped so "nothing hosted" can be told from "not a hosting message".
    struct Hosted { let ref: EmbedRef? }

    static func hosting(_ text: String) -> Hosted? {
        guard text.contains("\"dggApi:hosting\""),
              let envelope = try? JSONDecoder().decode(HostEnvelope.self, from: Data(text.utf8))
        else { return nil }
        guard let host = envelope.data, let platform = host.platform, let id = host.id else {
            return Hosted(ref: nil)
        }
        return Hosted(ref: ref(platform: platform, id: id))
    }

    private struct InfoEnvelope: Decodable {
        struct Info: Decodable {
            struct Stream: Decodable { let live: Bool?; let id: String?; let platform: String? }
            let streams: [String: Stream?]
        }
        let data: Info
    }

    static func destinyLive(_ text: String) -> [EmbedRef]? {
        guard text.contains("\"dggApi:streamInfo\""),
              let envelope = try? JSONDecoder().decode(InfoEnvelope.self, from: Data(text.utf8))
        else { return nil }
        return envelope.data.streams.compactMap { key, stream in
            guard let stream, stream.live == true, let id = stream.id else { return nil }
            return ref(platform: stream.platform ?? key, id: id)
        }
    }

    static func parse(_ text: String) -> [Item]? {
        // The feed carries plenty else, some of it large.
        guard text.contains("\"dggApi:embeds\""),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(text.utf8))
        else { return nil }
        return envelope.data.compactMap(\.entry).compactMap { entry in
            guard let platform = EmbedRef.Platform(rawValue: entry.platform.lowercased())
            else { return nil }
            let folded = platform == .twitch || platform == .kick
            let meta = entry.mediaItem?.metadata
            return Item(ref: EmbedRef(platform: platform,
                                      path: folded ? entry.id.lowercased() : entry.id),
                        watching: entry.count ?? 0,
                        name: meta?.displayName,
                        title: meta?.title,
                        live: meta?.live,
                        preview: meta?.previewUrl.flatMap(URL.init(string:)))
        }
    }
}

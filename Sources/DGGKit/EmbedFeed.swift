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
    }

    private static let endpoint = URL(string: "wss://live.destiny.gg")!

    private struct Envelope: Decodable {
        struct Entry: Decodable {
            struct Media: Decodable {
                struct Metadata: Decodable {
                    let displayName: String?
                    let title: String?
                    let live: Bool?
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

    public init() {}

    /// Every list the site publishes, reconnecting for as long as it's listened to.
    public func updates() -> AsyncStream<[Item]> {
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

    private static func listen(_ out: AsyncStream<[Item]>.Continuation,
                               connected: () -> Void) async {
        let socket = URLSession.shared.webSocketTask(with: endpoint)
        socket.maximumMessageSize = 8 * 1024 * 1024
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }

        let keepAlive = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                socket.sendPing { _ in }
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
            if let text, let items = parse(text) { out.yield(items) }
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
                        live: meta?.live)
        }
    }
}

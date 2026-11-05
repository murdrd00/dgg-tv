import Foundation

/// A DGG emote: a word in chat that renders as an image.
/// From cdn.destiny.gg/emotes/emotes.json (325 entries).
public struct Emote: Decodable, Sendable, Hashable {

    public struct Image: Decodable, Sendable, Hashable {
        public let url: String?
        public let width: Int?
        public let height: Int?
    }

    public let prefix: String
    public let image: [Image]?
    public let minimumSubTier: Int?

    public var url: String? {
        image?.compactMap(\.url).first { !$0.isEmpty }
    }
}

private struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

public actor EmoteCatalog {

    public static let shared = EmoteCatalog()
    public static let manifest = URL(string: "https://cdn.destiny.gg/emotes/emotes.json")!

    private var byPrefix: [String: Emote] = [:]
    private var loaded = false

    public init() {}

    @discardableResult
    public func load() async -> Int {
        guard !loaded else { return byPrefix.count }
        guard let (data, _) = try? await URLSession.shared.data(from: Self.manifest),
              let rows = try? JSONDecoder().decode([Lenient<Emote>].self, from: data)
        else { return 0 }
        let emotes = rows.compactMap(\.value).filter { $0.url != nil }
        guard !emotes.isEmpty else { return 0 }
        byPrefix = Dictionary(emotes.map { ($0.prefix, $0) }, uniquingKeysWith: { a, _ in a })
        loaded = true
        return byPrefix.count
    }

    public func snapshot() -> [String: Emote] { byPrefix }
}

import Foundation

/// A DGG emote: a word in chat that renders as an image.
/// From r2cdn.destiny.gg/emotes/emotes.json.
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
    public static let manifest = URL(string: "https://r2cdn.destiny.gg/emotes/emotes.json")!

    private var byPrefix: [String: Emote] = [:]
    private var loaded = false

    public init() {}

    @discardableResult
    public func load() async -> Int {
        if !loaded { await refresh() }
        return byPrefix.count
    }

    /// Fetches the list again, past any cached copy. New emotes go live on the
    /// site without an app update, and an app left running for days would never
    /// see them otherwise. True if anything changed.
    @discardableResult
    public func refresh() async -> Bool {
        var request = URLRequest(url: Self.manifest)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let rows = try? JSONDecoder().decode([Lenient<Emote>].self, from: data)
        else { return false }
        let emotes = rows.compactMap(\.value).filter { $0.url != nil }
        guard !emotes.isEmpty else { return false }
        let fresh = Dictionary(emotes.map { ($0.prefix, $0) }, uniquingKeysWith: { a, _ in a })
        defer { loaded = true }
        guard fresh != byPrefix else { return false }
        byPrefix = fresh
        return true
    }

    public func snapshot() -> [String: Emote] { byPrefix }
}

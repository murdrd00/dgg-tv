import Foundation

/// A DGG flair: the badge before a nick and the colour of the nick itself.
/// Loaded from r2cdn.destiny.gg/flairs/flairs.json.
public struct Flair: Decodable, Sendable, Hashable {

    public struct Image: Decodable, Sendable, Hashable {
        /// Nullable in the live manifest — at least one entry ships `"url": null`.
        public let url: String?
        public let width: Int?
        public let height: Int?
    }

    public let name: String
    public let label: String
    public let color: String?
    public let priority: Int
    public let hidden: Bool
    public let rainbowColor: Bool
    public let image: [Image]?

    /// Hidden flairs tint the nick but show no badge.
    public var iconURL: String? {
        guard !hidden else { return nil }
        return image?.compactMap(\.url).first { !$0.isEmpty }
    }

    public var hasColor: Bool { !(color ?? "").isEmpty }
}

/// Decodes an element, or swallows it, so one malformed entry in a
/// third-party manifest can't take the whole catalogue down with it.
private struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

public actor FlairCatalog {

    public static let shared = FlairCatalog()
    public static let manifest = URL(string: "https://r2cdn.destiny.gg/flairs/flairs.json")!

    private var byName: [String: Flair] = [:]
    private var loaded = false

    public init() {}

    @discardableResult
    public func load() async -> Int {
        if !loaded { await refresh() }
        return byName.count
    }

    /// Fetches the list again, past any cached copy. True if anything changed.
    @discardableResult
    public func refresh() async -> Bool {
        var request = URLRequest(url: Self.manifest)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let rows = try? JSONDecoder().decode([Lenient<Flair>].self, from: data)
        else { return false }
        let flairs = rows.compactMap(\.value)
        guard !flairs.isEmpty else { return false }
        let fresh = Dictionary(flairs.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        defer { loaded = true }
        guard fresh != byName else { return false }
        byName = fresh
        return true
    }

    public func snapshot() -> [String: Flair] { byName }
}

/// Resolved presentation for one chat line, computed once per message.
public struct FlairStyle: Sendable, Hashable {
    public let colorHex: String?
    public let rainbow: Bool
    public let badges: [String]      // icon URLs, highest priority first
    public let labels: [String]

    public static let plain = FlairStyle(colorHex: nil, rainbow: false,
                                         badges: [], labels: [])

    /// Lower `priority` wins, which is how the site ranks them.
    public static func resolve(features: [String],
                               catalog: [String: Flair]) -> FlairStyle {
        let mine = features.compactMap { catalog[$0] }
            .sorted { $0.priority < $1.priority }
        guard !mine.isEmpty else { return .plain }

        let tint = mine.first(where: \.hasColor)
        let visible = mine.filter { $0.iconURL != nil }

        return FlairStyle(
            colorHex: tint?.color,
            rainbow: tint?.rainbowColor ?? false,
            badges: visible.compactMap(\.iconURL),
            labels: visible.map(\.label)
        )
    }
}

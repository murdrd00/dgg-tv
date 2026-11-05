import Foundation

/// The live embed list, ranked the way the site ranks it: by how many people
/// are actually watching each one.
///
/// Every MSG and UPDATEUSER frame carries the sender's `watching` field, and
/// NAMES carries it for every connected user — so the list is fully populated
/// the moment we connect, instead of waiting for someone to type "#kick/x".
public final class EmbedTracker: @unchecked Sendable {

    public struct Entry: Sendable, Identifiable {
        public let ref: EmbedRef
        public var viewers: Int
        public var lastMentioned: Date?
        public var id: String { ref.token }
    }

    /// nick -> what they're watching right now. One entry per user, so a user
    /// switching embeds moves their vote rather than double-counting.
    private var watchingByNick: [String: EmbedRef] = [:]
    /// Embeds someone typed into chat but nobody is watching yet.
    private var mentioned: [String: (ref: EmbedRef, at: Date)] = [:]

    private let capacity: Int
    private let lock = NSLock()

    public init(capacity: Int = 12) { self.capacity = capacity }

    public func seed(users: [ChatUser]) {
        lock.lock(); defer { lock.unlock() }
        for u in users {
            if let e = u.watching?.embed { watchingByNick[u.nick] = e }
        }
    }

    public func update(_ user: ChatUser) {
        lock.lock(); defer { lock.unlock() }
        if let e = user.watching?.embed { watchingByNick[user.nick] = e }
        else { watchingByNick.removeValue(forKey: user.nick) }
    }

    /// Feed every chat line through this.
    @discardableResult
    public func observe(_ line: ChatLine) -> [EmbedRef] {
        lock.lock(); defer { lock.unlock() }
        if let e = line.watching?.embed { watchingByNick[line.nick] = e }

        let typed = EmbedRef.scan(line.text)
        for ref in typed { mentioned[ref.token] = (ref, line.at) }
        return typed
    }

    public func ranked() -> [Entry] {
        lock.lock(); defer { lock.unlock() }

        var counts: [String: (ref: EmbedRef, n: Int)] = [:]
        for ref in watchingByNick.values {
            counts[ref.token, default: (ref, 0)].n += 1
        }

        var out = counts.values
            .map { Entry(ref: $0.ref, viewers: $0.n,
                         lastMentioned: mentioned[$0.ref.token]?.at) }
            .sorted { $0.viewers > $1.viewers }

        // Embeds just posted in chat that nobody has switched to yet.
        let cutoff = Date().addingTimeInterval(-600)
        let fresh = mentioned.values
            .filter { $0.at > cutoff && counts[$0.ref.token] == nil }
            .sorted { $0.at > $1.at }
            .map { Entry(ref: $0.ref, viewers: 0, lastMentioned: $0.at) }

        out.append(contentsOf: fresh)
        return Array(out.prefix(capacity))
    }

    public var totalTracked: Int {
        lock.lock(); defer { lock.unlock() }
        return watchingByNick.count
    }
}

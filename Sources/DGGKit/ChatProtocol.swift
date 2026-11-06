import Foundation

// DGG frames are "<VERB> <json>". Verbs observed live:
// MSG, NAMES, HISTORY, UPDATEUSER, PIN, SPOTLIGHT, SPOTLIGHTS, PAIDEVENTS, ME.

/// What a user currently has open on bigscreen. This is the real source of
/// the embed list — the site ranks embeds by how many people are watching,
/// not by who typed "#kick/x".
public struct Watching: Decodable, Sendable, Hashable {
    public let platform: String
    public let id: String

    public var embed: EmbedRef? {
        guard let p = EmbedRef.Platform(rawValue: platform.lowercased()) else { return nil }
        let foldable = (p == .twitch || p == .kick)
        return EmbedRef(platform: p, path: foldable ? id.lowercased() : id)
    }
}

public struct ChatUser: Decodable, Sendable, Hashable {
    public let nick: String
    public let features: [String]
    public let watching: Watching?

    enum CodingKeys: String, CodingKey { case nick, features, watching }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nick = (try? c.decode(String.self, forKey: .nick)) ?? ""
        features = (try? c.decode([String].self, forKey: .features)) ?? []
        watching = try? c.decodeIfPresent(Watching.self, forKey: .watching)
    }
}

struct MessagePayload: Decodable {
    let nick: String?
    let features: [String]?
    let timestamp: Int64?
    let data: String?
    let watching: Watching?
}

struct NamesPayload: Decodable {
    let connectioncount: Int?
    let users: [ChatUser]?
}

/// A chat poll. Built by hand from loose JSON: no live poll was available to
/// check the types against, and the site's client treats `vote` as a string in
/// some places and a number in others.
public struct ChatPoll: Sendable, Equatable {
    public var question: String
    public var options: [String]
    public var totals: [Int]
    public var votes: Int
    public var startedBy: String
    public var canVote: Bool
    /// 1-based, and 0 if we haven't voted.
    public var myVote: Int
    public var weighted: Bool
    /// Totals stay secret until the poll ends.
    public var hidden: Bool
    public var ends: Date
    /// How long it runs in all, to show how much is left.
    public var length: TimeInterval
    public var ended = false

    init?(json: [String: Any], received: Date = Date()) {
        guard let question = json["question"] as? String,
              let options = json["options"] as? [String], !options.isEmpty else { return nil }
        self.question = question
        self.options = options
        let totals = (json["totals"] as? [Any])?.map { Self.int($0) } ?? []
        self.totals = totals.count == options.count
            ? totals : Array(repeating: 0, count: options.count)
        votes = Self.int(json["totalvotes"])
        startedBy = json["nick"] as? String ?? ""
        canVote = json["canvote"] as? Bool ?? false
        myVote = Self.int(json["myvote"])
        weighted = json["weighted"] as? Bool ?? false
        hidden = json["hidden"] as? Bool ?? false

        // By the server's clock, so joining a running poll shows the time left.
        length = Double(Self.int(json["time"])) / 1000
        var elapsed = 0.0
        if let start = Self.date(json["start"]), let now = Self.date(json["now"]) {
            elapsed = max(0, now.timeIntervalSince(start))
        }
        ends = received.addingTimeInterval(max(0, length - elapsed))
    }

    static func int(_ value: Any?) -> Int {
        if let n = value as? Int { return n }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) ?? 0 }
        return 0
    }

    private static func date(_ value: Any?) -> Date? {
        if let ms = value as? Double { return Date(timeIntervalSince1970: ms / 1000) }
        guard let s = value as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

public enum ChatEvent: Sendable {
    case connected
    /// The pinned message, sent on connecting and when it changes. A nil line
    /// means nothing is pinned.
    case pin(id: String, line: ChatLine?)
    case pollStart(ChatPoll)
    /// Totals only come with a poll whose results were hidden.
    case pollStop(totals: [Int]?, votes: Int?)
    /// Someone's vote. `option` is 1-based, or 0 when hidden.
    case voteCast(option: Int, quantity: Int)
    /// Ours went through.
    case voteCounted(option: Int)
    /// Who chat thinks we are, sent on connecting. Nil means a guest.
    case me(nick: String?)
    case message(ChatLine)
    case history([ChatLine])
    case userUpdate(ChatUser)
    case broadcast(text: String, at: Date)
    case names(count: Int, users: [ChatUser])
    case join(nick: String)
    case quit(nick: String)
    case unhandled(verb: String, json: String)
    /// A mute/ban. The web client purges that nick's messages, so we do too.
    case moderated(nick: String, action: String)
    case protocolError(String)
    case disconnected(reason: String)
    case reconnecting(attempt: Int, inSeconds: TimeInterval)
}

public struct ChatLine: Sendable, Identifiable, Hashable {
    public let id = UUID()
    public let nick: String
    public let features: [String]
    public let text: String
    public let at: Date
    public let watching: Watching?

    public init(nick: String, features: [String], text: String,
                at: Date, watching: Watching?) {
        self.nick = nick
        self.features = features
        self.text = text
        self.at = at
        self.watching = watching
    }

    public var primaryFlair: String? {
        let ranked = ["admin", "bot", "broadcaster", "moderator", "vip",
                      "protected", "subscriber"]
        return ranked.first(where: features.contains)
    }
}

public enum FrameParser {

    public static func split(_ raw: String) -> (verb: String, json: String)? {
        guard let sp = raw.firstIndex(of: " ") else {
            let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : (v, "")
        }
        return (String(raw[raw.startIndex..<sp]),
                String(raw[raw.index(after: sp)...]))
    }

    private static func line(from p: MessagePayload) -> ChatLine? {
        guard let nick = p.nick, let text = p.data else { return nil }
        let at = p.timestamp.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? Date()
        return ChatLine(nick: nick, features: p.features ?? [],
                        text: text, at: at, watching: p.watching)
    }

    private static func object(_ bytes: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
    }

    public static func parse(_ raw: String) -> ChatEvent? {
        guard let (verb, json) = split(raw) else { return nil }
        let bytes = Data(json.utf8)
        let dec = JSONDecoder()

        switch verb {
        case "ME":
            let me = try? JSONSerialization.jsonObject(with: bytes, options: .fragmentsAllowed)
            return .me(nick: (me as? [String: Any])?["nick"] as? String)

        case "PIN":
            let id = object(bytes)?["uuid"] as? String ?? ""
            let payload = try? dec.decode(MessagePayload.self, from: bytes)
            let pinned = payload.flatMap(line(from:))
            return .pin(id: id, line: pinned?.text.isEmpty == false ? pinned : nil)

        case "POLLSTART":
            return object(bytes).flatMap { ChatPoll(json: $0) }.map { .pollStart($0) }

        case "POLLSTOP":
            let o = object(bytes)
            return .pollStop(totals: (o?["totals"] as? [Any])?.map { ChatPoll.int($0) },
                             votes: o?["totalvotes"].map { ChatPoll.int($0) })

        case "VOTECAST":
            guard let o = object(bytes) else { return nil }
            return .voteCast(option: ChatPoll.int(o["vote"]), quantity: ChatPoll.int(o["quantity"]))

        case "VOTECOUNTED":
            guard let o = object(bytes) else { return nil }
            return .voteCounted(option: ChatPoll.int(o["vote"]))

        case "MSG":
            guard let p = try? dec.decode(MessagePayload.self, from: bytes),
                  let l = line(from: p) else { return nil }
            return .message(l)

        case "HISTORY":
            // An array of raw "MSG {...}" strings replayed on connect.
            guard let raws = try? dec.decode([String].self, from: bytes) else { return nil }
            let lines: [ChatLine] = raws.compactMap { entry in
                guard let (v, j) = split(entry), v == "MSG",
                      let p = try? dec.decode(MessagePayload.self, from: Data(j.utf8))
                else { return nil }
                return line(from: p)
            }
            return .history(lines)

        case "UPDATEUSER":
            guard let u = try? dec.decode(ChatUser.self, from: bytes) else { return nil }
            return .userUpdate(u)

        case "BROADCAST":
            guard let p = try? dec.decode(MessagePayload.self, from: bytes) else { return nil }
            let at = p.timestamp.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? Date()
            return .broadcast(text: p.data ?? "", at: at)

        case "NAMES":
            guard let p = try? dec.decode(NamesPayload.self, from: bytes) else { return nil }
            return .names(count: p.connectioncount ?? 0, users: p.users ?? [])

        case "JOIN":
            guard let p = try? dec.decode(MessagePayload.self, from: bytes) else { return nil }
            return .join(nick: p.nick ?? "")
        case "QUIT":
            guard let p = try? dec.decode(MessagePayload.self, from: bytes) else { return nil }
            return .quit(nick: p.nick ?? "")
        case "MUTE", "BAN", "IPBAN":
            // The moderator is in `nick`; the TARGET is in `data`.
            guard let p = try? dec.decode(MessagePayload.self, from: bytes),
                  let target = p.data, !target.isEmpty else { return nil }
            return .moderated(nick: target, action: verb)

        case "ERR":
            return .protocolError(json)
        default:
            return .unhandled(verb: verb, json: json)
        }
    }
}

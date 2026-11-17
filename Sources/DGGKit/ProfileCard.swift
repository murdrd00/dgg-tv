import Foundation

/// The Membership Card from a destiny.gg profile page, destiny.gg/u/<name>.
///
/// The page is public, so this needs only the name, never the Login Key. There's
/// no API for the card, so it's read from the page's HTML by its `id-card__`
/// classes. Editing stays on the site: doing it from here would mean posting the
/// site's own forms as the user, which is fragile and not worth the risk.
public struct ProfileCard: Sendable, Equatable {
    public struct Field: Sendable, Equatable, Hashable {
        public let label: String
        public let value: String
    }

    public let name: String
    public let tier: String?
    public let team: String?
    public let since: String?
    public let fields: [Field]
    public let bio: String?
    public let photo: URL?
    /// The hand-drawn signature, as SVG path data in a 5900 x 1000 box.
    public let signature: String?
    public let memberNumber: String?
    public let page: URL

    public static func page(for name: String) -> URL? {
        let safe = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        return URL(string: "https://www.destiny.gg/u/\(safe)")
    }

    public static func load(name: String) async -> ProfileCard? {
        guard let url = page(for: name) else { return nil }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(String(decoding: data, as: UTF8.self), page: url)
    }

    static func parse(_ html: String, page: URL) -> ProfileCard? {
        guard let start = html.range(of: "class=\"id-card\"") else { return nil }
        let card = String(html[start.lowerBound...])

        func text(_ cls: String) -> String? {
            // The element whose class list includes `cls`, up to its close tag.
            let pattern = "class=\"[^\"]*(?<=[\\s\"])\(NSRegularExpression.escapedPattern(for: cls))(?=[\\s\"])[^\"]*\"[^>]*>(.*?)</(?:span|div|p)>"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
                  let m = regex.firstMatch(in: card, range: NSRange(card.startIndex..., in: card)),
                  let r = Range(m.range(at: 1), in: card) else { return nil }
            return clean(String(card[r]))
        }

        func attribute(_ name: String, on cls: String) -> String? {
            let pattern = "<[^>]*class=\"[^\"]*(?<=[\\s\"])\(NSRegularExpression.escapedPattern(for: cls))(?=[\\s\"])[^\"]*\"[^>]*>"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
                  let m = regex.firstMatch(in: card, range: NSRange(card.startIndex..., in: card)),
                  let r = Range(m.range, in: card) else { return nil }
            let tag = String(card[r])
            guard let a = tag.range(of: "\(name)=\""),
                  let b = tag[a.upperBound...].firstIndex(of: "\"") else { return nil }
            return String(tag[a.upperBound..<b])
        }

        var fields: [Field] = []
        if let regex = try? NSRegularExpression(
            pattern: "class=\"id-card__field\"\\s*>\\s*<span class=\"id-card__label\">(.*?)</span>\\s*<span[^>]*>(.*?)</span>",
            options: [.dotMatchesLineSeparators]) {
            for m in regex.matches(in: card, range: NSRange(card.startIndex..., in: card)) {
                guard let l = Range(m.range(at: 1), in: card), let v = Range(m.range(at: 2), in: card),
                      let label = clean(String(card[l])), let value = clean(String(card[v])) else { continue }
                fields.append(Field(label: label, value: value))
            }
        }

        guard let name = text("id-card__name") else { return nil }
        let number: String? = {
            guard let i = card.range(of: "Member No.") else { return nil }
            let rest = String(card[i.upperBound...].prefix(400))
            let regex = try? NSRegularExpression(pattern: ">\\s*([A-Z]+-\\d+)\\s*<")
            guard let m = regex?.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
                  let r = Range(m.range(at: 1), in: rest) else { return nil }
            return String(rest[r])
        }()
        let signature: String? = {
            guard let i = card.range(of: "id-card__signature-image"),
                  let d = card[i.upperBound...].range(of: " d=\""),
                  let end = card[d.upperBound...].firstIndex(of: "\"") else { return nil }
            return String(card[d.upperBound..<end])
        }()

        return ProfileCard(
            name: name,
            tier: text("id-card__tier"),
            team: text("id-card__team"),
            since: text("id-card__since"),
            fields: fields,
            bio: text("id-card__bio-text"),
            photo: attribute("src", on: "id-card__photo").flatMap(URL.init(string:)),
            signature: signature,
            memberNumber: number,
            page: page)
    }

    private static func clean(_ html: String) -> String? {
        var s = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                               ("&#039;", "'"), ("&#39;", "'"), ("&nbsp;", " ")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}

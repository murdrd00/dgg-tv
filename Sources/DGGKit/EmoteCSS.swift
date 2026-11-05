import Foundation

/// What the site does to emotes lives in one stylesheet: 2,600 rules covering
/// animation, secret variants and combinations. They're written against the
/// page's DOM, so rather than special-casing emotes, this reads the real sheet
/// and matches it against a small model of each chat line, the way a browser
/// would. New and changed emotes need no code.

// MARK: - What the caller gets

public struct EmoteContext: Sendable {
    public var username: String
    public var flairs: [String]
    /// The message directly above. Some emotes change based on who sent it.
    public var previousUsername: String?
    /// Set for combo lines, which are a different kind of message.
    public var comboCount: Int?
    /// Every emote in the message, in order.
    public var emotes: [String]

    public init(username: String, flairs: [String] = [], previousUsername: String? = nil,
                comboCount: Int? = nil, emotes: [String]) {
        self.username = username
        self.flairs = flairs
        self.previousUsername = previousUsername
        self.comboCount = comboCount
        self.emotes = emotes
    }
}

public struct EmoteKeyframe: Sendable {
    public var offset: Double
    public var properties: [String: String]
}

public struct EmoteAnimation: Sendable {
    public var keyframes: [EmoteKeyframe]
    public var duration: Double
    public var delay: Double
    public var iterations: Double
    public var steps: Int?
    public var timing: String
    public var holdsEnd: Bool
    public var alternates: Bool
}

/// One drawn box: the emote itself, or a ::before / ::after piece of it.
public struct EmotePart: Sendable {
    public var image: String?
    public var width: Double
    public var height: Double
    /// Where in the image the box starts. A CSS position moves the image the
    /// opposite way, and its sign matters: CuckCrab runs from +704 to -2240.
    public var backgroundX: Double
    public var left: Double
    public var top: Double
    public var transform: String?
    public var origin: String?
    public var opacity: Double
    public var animations: [EmoteAnimation]

    private func animated(_ property: String) -> Double? {
        for a in animations {
            for frame in a.keyframes {
                if let v = CSS.px(frame.properties[property]) { return v }
            }
        }
        return nil
    }

    /// Some emotes animate their own box: PepoPunch rests at 47px but plays at
    /// 56px with a negative margin, so its space in the line stays the same.
    public var drawnWidth: Double { animated("width") ?? width }
    public var drawnOffset: Double { animated("margin-left") ?? 0 }
}

public struct EmoteLook: Sendable {
    public var name: String
    public var base: EmotePart
    public var extras: [EmotePart]
    public var marginLeft: Double
    public var marginRight: Double
    /// The space it takes up in the line, in CSS pixels.
    public var advance: Double { max(1, base.width + marginLeft + marginRight) }
}

// MARK: - The stylesheet

public final class EmoteStyleSheet: @unchecked Sendable {

    private struct Rule {
        let selector: Selector
        let declarations: [(String, String)]
        let specificity: Int
        let order: Int
    }

    private var byEmote: [String: [Rule]] = [:]
    private var general: [Rule] = []
    private var keyframes: [String: [EmoteKeyframe]] = [:]
    private let base: String
    public private(set) var ruleCount = 0

    /// Derived from any emote image, since both share a versioned folder.
    public static func load(anyEmoteImageURL url: String) async -> EmoteStyleSheet? {
        guard let i = url.range(of: "/emotes/") else { return nil }
        let folder = String(url[url.startIndex..<i.upperBound])
        guard let css = URL(string: folder + "emotes.css"),
              let (data, _) = try? await URLSession.shared.data(from: css)
        else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return await Task.detached { EmoteStyleSheet(css: text, base: folder) }.value
    }

    public init(css: String, base: String) {
        self.base = base
        var parser = StyleParser(css)
        var order = 0
        parser.parse(
            rule: { [self] selectorText, declarations in
                for text in splitTopLevel(selectorText, on: ",") {
                    guard let selector = SelectorParser.parse(text),
                          selector.mentions(class: "emote") else { continue }
                    order += 1
                    let rule = Rule(selector: selector, declarations: declarations,
                                    specificity: selector.specificity, order: order)
                    ruleCount += 1
                    if let name = selector.targetEmote {
                        byEmote[name, default: []].append(rule)
                    } else {
                        general.append(rule)
                    }
                }
            },
            keyframes: { [self] name, frames in keyframes[name] = frames })
    }

    /// One look per emote in the message, in the same order.
    public func looks(for context: EmoteContext) -> [EmoteLook] {
        let (nodes, root) = Self.model(of: context)
        // Nodes only hold their parents weakly, so the page must outlive this.
        return withExtendedLifetime(root) {
            zip(context.emotes, nodes).map { look(name: $0, node: $1) }
        }
    }

    private func look(name: String, node: Node) -> EmoteLook {
        let rules = (byEmote[name] ?? []) + general
        let main = computed(rules, node, pseudo: nil)
        let before = computed(rules, node, pseudo: "before")
        let after = computed(rules, node, pseudo: "after")
        let basePart = part(main, inherit: nil)
        return EmoteLook(
            name: name,
            base: basePart,
            extras: [before, after].filter { !$0.isEmpty }.map { part($0, inherit: main) }
                .filter { $0.image != nil },
            marginLeft: CSS.px(main["margin-left"]) ?? 0,
            marginRight: CSS.px(main["margin-right"]) ?? 0)
    }

    private func computed(_ rules: [Rule], _ node: Node, pseudo: String?) -> [String: String] {
        let matched = rules
            .filter { $0.selector.pseudoElement == pseudo && $0.selector.matches(node) }
            .sorted { ($0.specificity, $0.order) < ($1.specificity, $1.order) }
        var out: [String: String] = [:]
        var important: Set<String> = []
        for rule in matched {
            for (key, raw) in rule.declarations {
                let isImportant = raw.contains("!important")
                let value = raw.replacingOccurrences(of: "!important", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if important.contains(key) && !isImportant { continue }
                if isImportant { important.insert(key) }
                out[key] = value
            }
        }
        return out
    }

    private func part(_ style: [String: String], inherit: [String: String]?) -> EmotePart {
        func get(_ key: String) -> String? {
            style[key].map { CSS.resolveVars($0, style.merging(inherit ?? [:]) { a, _ in a }) }
        }
        var image: String?
        if let bg = get("background-image") ?? get("background"),
           let url = CSS.url(in: bg) {
            image = url.hasPrefix("data:") || url.hasPrefix("http") ? url : base + url
        }
        return EmotePart(
            image: image,
            width: CSS.px(get("width")) ?? 0,
            height: CSS.px(get("height")) ?? 30,
            backgroundX: -(CSS.px(get("background-position")) ?? 0),
            left: CSS.px(get("left")) ?? 0,
            top: CSS.px(get("top")) ?? 0,
            transform: get("transform"),
            origin: get("transform-origin"),
            opacity: get("opacity").flatMap(Double.init) ?? 1,
            animations: animations(style, inherit: inherit))
    }

    private func animations(_ style: [String: String],
                            inherit: [String: String]?) -> [EmoteAnimation] {
        let vars = style.merging(inherit ?? [:]) { a, _ in a }
        guard let raw = style["animation"].map({ CSS.resolveVars($0, vars) }) else { return [] }
        var out: [EmoteAnimation] = []
        for one in splitTopLevel(raw, on: ",") {
            guard var a = CSS.animation(one), let name = a.name,
                  let frames = keyframes[name] else { continue }
            if let v = style["animation-delay"].flatMap(CSS.seconds) { a.delay = v }
            if let v = style["animation-duration"].flatMap(CSS.seconds) { a.duration = v }
            if let v = style["animation-iteration-count"] {
                a.iterations = v.contains("infinite") ? .infinity : Double(v) ?? a.iterations
            }
            if let v = style["animation-timing-function"] { a.apply(timing: v) }
            let resolved = frames.map { frame in
                EmoteKeyframe(offset: frame.offset, properties: frame.properties
                    .mapValues { CSS.resolveVars($0, vars) })
            }
            out.append(EmoteAnimation(keyframes: resolved, duration: a.duration, delay: a.delay,
                                      iterations: a.iterations, steps: a.steps,
                                      timing: a.timing, holdsEnd: a.holdsEnd,
                                      alternates: a.alternates))
        }
        return out
    }

    /// The page structure these selectors were written against.
    private static func model(of c: EmoteContext) -> (emotes: [Node], root: Node) {
        let list = Node(classes: ["chat-lines"])
        if let previous = c.previousUsername {
            let prior = Node(classes: ["msg-chat", "msg-user"])
            prior.attributes["data-username"] = previous.lowercased()
            list.add(prior)
        }
        let message = Node(classes: c.comboCount == nil
                           ? ["msg-chat", "msg-user"] : ["msg-chat", "msg-emote"])
        list.add(message)
        if let count = c.comboCount {
            message.attributes["data-combo"] = "\(count)"
            message.attributes["data-combo-group"] = "\(count / 5 * 5)"
        } else {
            message.attributes["data-username"] = c.username.lowercased()
            message.add(Node(classes: Set(["user", "chat-user"] + c.flairs)))
        }
        let text = Node(classes: ["text"])
        message.add(text)
        let emotes = c.emotes.map { Node(classes: ["emote", $0]) }
        emotes.forEach(text.add)
        return (emotes, list)
    }
}

// MARK: - Values

enum CSS {
    static func resolveVars(_ value: String, _ style: [String: String]) -> String {
        var v = value
        var guardCount = 0
        while let r = v.range(of: "var("), guardCount < 8 {
            guardCount += 1
            guard let end = closing(v, from: r.upperBound) else { break }
            let inner = String(v[r.upperBound..<end])
            let parts = splitTopLevel(inner, on: ",", limit: 2)
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let fallback = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            v.replaceSubrange(r.lowerBound...end, with: style[name] ?? fallback)
        }
        return v
    }

    private static func closing(_ s: String, from: String.Index) -> String.Index? {
        var depth = 1
        var i = from
        while i < s.endIndex {
            if s[i] == "(" { depth += 1 }
            if s[i] == ")" { depth -= 1; if depth == 0 { return i } }
            i = s.index(after: i)
        }
        return nil
    }

    static func px(_ value: String?) -> Double? {
        guard let v = value?.trimmingCharacters(in: .whitespaces) else { return nil }
        let first = v.split(separator: " ").first.map(String.init) ?? v
        if first == "0" { return 0 }
        guard first.hasSuffix("px") else { return nil }
        return Double(first.dropLast(2))
    }

    static func url(in value: String) -> String? {
        guard let r = value.range(of: "url("), let end = closing(value, from: r.upperBound)
        else { return nil }
        return value[r.upperBound..<end].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }

    /// `1.5s`, `300ms`, or `calc(3.5s / 1)`.
    static func seconds(_ raw: String) -> Double? {
        var v = raw.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("calc("), v.hasSuffix(")") {
            let inner = v.dropFirst(5).dropLast()
            let parts = inner.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let a = parts.first.flatMap(seconds) else { return nil }
            let b = parts.count > 1 ? Double(parts[1]) ?? 1 : 1
            return b == 0 ? a : a / b
        }
        if v.hasSuffix("ms") { v.removeLast(2); return Double(v).map { $0 / 1000 } }
        if v.hasSuffix("s") { v.removeLast(); return Double(v) }
        return nil
    }

    struct Shorthand {
        var name: String?
        var duration = 0.0
        var delay = 0.0
        var iterations = 1.0
        var steps: Int?
        var timing = "ease"
        var holdsEnd = false
        var alternates = false

        mutating func apply(timing token: String) {
            if token.hasPrefix("steps(") {
                let n = token.dropFirst(6).prefix { $0.isNumber }
                steps = Int(n)
            } else {
                timing = token
            }
        }
    }

    static func animation(_ text: String) -> Shorthand? {
        var a = Shorthand()
        var sawDuration = false
        for token in splitTopLevel(text, on: " ") where !token.isEmpty {
            if token == "none" { return nil }
            if let s = seconds(token) {
                if sawDuration { a.delay = s } else { a.duration = s; sawDuration = true }
            } else if token == "infinite" {
                a.iterations = .infinity
            } else if let n = Double(token) {
                a.iterations = n
            } else if token.hasPrefix("steps(") || token.hasPrefix("cubic-bezier(")
                        || ["ease", "linear", "ease-in", "ease-out", "ease-in-out"].contains(token) {
                a.apply(timing: token)
            } else if token == "forwards" || token == "both" {
                a.holdsEnd = true
            } else if token == "alternate" || token == "alternate-reverse" {
                a.alternates = true
            } else if !["normal", "running", "paused", "backwards"].contains(token) {
                a.name = token
            }
        }
        return a
    }
}

/// Splits on a separator outside brackets and quotes.
func splitTopLevel(_ text: String, on separator: Character, limit: Int = .max) -> [String] {
    var out: [String] = []
    var current = ""
    var depth = 0
    var quote: Character?
    for ch in text {
        if let q = quote {
            if ch == q { quote = nil }
        } else if ch == "\"" || ch == "'" {
            quote = ch
        } else if ch == "(" || ch == "[" {
            depth += 1
        } else if ch == ")" || ch == "]" {
            depth -= 1
        }
        let isSeparator = separator == " " ? ch.isWhitespace : ch == separator
        if isSeparator && depth == 0 && quote == nil && out.count < limit - 1 {
            out.append(current)
            current = ""
        } else {
            current.append(ch)
        }
    }
    out.append(current)
    return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Reading the file

private struct StyleParser {
    private let bytes: [UInt8]

    init(_ css: String) {
        var text = css
        while let open = text.range(of: "/*") {
            guard let close = text.range(of: "*/", range: open.upperBound..<text.endIndex)
            else { text.removeSubrange(open.lowerBound...); break }
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        bytes = Array(text.utf8)
    }

    func parse(rule: (String, [(String, String)]) -> Void,
               keyframes: (String, [EmoteKeyframe]) -> Void) {
        walk(0, bytes.count, rule: rule, keyframes: keyframes)
    }

    private func string(_ a: Int, _ b: Int) -> String {
        String(decoding: bytes[a..<b], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Index of the `}` matching the `{` before `start`.
    private func blockEnd(_ start: Int, _ limit: Int) -> Int {
        var depth = 1
        var i = start
        var quote: UInt8 = 0
        while i < limit {
            let c = bytes[i]
            if quote != 0 { if c == quote { quote = 0 } }
            else if c == 34 || c == 39 { quote = c }
            else if c == 123 { depth += 1 }
            else if c == 125 { depth -= 1; if depth == 0 { return i } }
            i += 1
        }
        return limit
    }

    private func walk(_ from: Int, _ to: Int,
                      rule: (String, [(String, String)]) -> Void,
                      keyframes: (String, [EmoteKeyframe]) -> Void) {
        var i = from
        var start = from
        var quote: UInt8 = 0
        var paren = 0
        while i < to {
            let c = bytes[i]
            if quote != 0 { if c == quote { quote = 0 } }
            else if c == 34 || c == 39 { quote = c }
            else if c == 40 { paren += 1 }
            else if c == 41 { paren -= 1 }
            else if c == 59 && paren == 0 { start = i + 1 }
            else if c == 123 && paren == 0 {
                let end = blockEnd(i + 1, to)
                let prelude = string(start, i)
                if prelude.hasPrefix("@keyframes") {
                    let name = prelude.dropFirst(10).trimmingCharacters(in: .whitespaces)
                    keyframes(name, frames(i + 1, end))
                } else if prelude.hasPrefix("@") {
                    walk(i + 1, end, rule: rule, keyframes: keyframes)
                } else {
                    rule(prelude, declarations(string(i + 1, end)))
                }
                i = end
                start = end + 1
            }
            i += 1
        }
    }

    private func frames(_ from: Int, _ to: Int) -> [EmoteKeyframe] {
        var out: [EmoteKeyframe] = []
        var i = from
        var start = from
        while i < to {
            if bytes[i] == 123 {
                let end = blockEnd(i + 1, to)
                let properties = Dictionary(declarations(string(i + 1, end)),
                                            uniquingKeysWith: { _, b in b })
                for selector in string(start, i).split(separator: ",") {
                    let s = selector.trimmingCharacters(in: .whitespaces)
                    let offset = s == "from" ? 0 : s == "to" ? 1
                        : Double(s.dropLast()).map { $0 / 100 }
                    if let offset { out.append(EmoteKeyframe(offset: offset, properties: properties)) }
                }
                i = end
                start = end + 1
            }
            i += 1
        }
        return out.sorted { $0.offset < $1.offset }
    }

    private func declarations(_ body: String) -> [(String, String)] {
        splitTopLevel(body, on: ";").compactMap { d in
            guard let colon = d.firstIndex(of: ":") else { return nil }
            let key = d[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = d[d.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return key.isEmpty ? nil : (key, value)
        }
    }
}

// MARK: - The page model

final class Node {
    var classes: Set<String>
    var attributes: [String: String] = [:]
    weak var parent: Node?
    var children: [Node] = []

    init(classes: Set<String>) { self.classes = classes }

    func add(_ child: Node) {
        child.parent = self
        children.append(child)
    }

    var siblings: [Node] { parent?.children ?? [self] }
    var index: Int { siblings.firstIndex { $0 === self } ?? 0 }
    var previousSiblings: [Node] { Array(siblings[..<index].reversed()) }
    var nextSiblings: [Node] { Array(siblings[(index + 1)...]) }
    var descendants: [Node] { children.flatMap { [$0] + $0.descendants } }
}

// MARK: - Selectors

enum Combinator { case descendant, child, next, subsequent }

indirect enum Simple {
    case cls(String)
    case attribute(name: String, op: String, value: String)
    case universal
    case not([Selector])
    case `is`([Selector])
    case has([Selector])
    case nth(a: Int, b: Int, fromEnd: Bool)
    case only

    var specificity: Int {
        switch self {
        case .universal: return 0
        case .not(let s), .is(let s), .has(let s):
            return s.map(\.specificity).max() ?? 0
        default: return 1
        }
    }
}

struct Compound {
    var simples: [Simple] = []
}

struct Selector {
    var compounds: [Compound] = []
    /// Between compounds[i] and compounds[i + 1].
    var combinators: [Combinator] = []
    /// Only inside `:has(+ .x)`.
    var leading: Combinator?
    var pseudoElement: String?

    var specificity: Int {
        compounds.reduce(0) { $0 + $1.simples.reduce(0) { $0 + $1.specificity } }
    }

    func mentions(class name: String) -> Bool {
        func check(_ s: Simple) -> Bool {
            switch s {
            case .cls(let c): return c == name
            case .is(let list), .has(let list): return list.contains { $0.mentions(class: name) }
            default: return false
            }
        }
        return compounds.contains { $0.simples.contains(where: check) }
    }

    /// The emote this applies to, for looking rules up by name.
    var targetEmote: String? {
        guard let last = compounds.last else { return nil }
        for simple in last.simples {
            if case .cls(let c) = simple, c != "emote" { return c }
        }
        return nil
    }

    func matches(_ node: Node) -> Bool {
        match(compounds.count - 1, node, anchor: nil)
    }

    private func match(_ i: Int, _ node: Node, anchor: Node?) -> Bool {
        guard compounds[i].simples.allSatisfy({ Self.test($0, node) }) else { return false }
        guard i > 0 else {
            guard let anchor else { return true }
            switch leading ?? .descendant {
            case .descendant: return anchor.descendants.contains { $0 === node }
            case .child:      return node.parent === anchor
            case .next:       return anchor.nextSiblings.first === node
            case .subsequent: return anchor.nextSiblings.contains { $0 === node }
            }
        }
        switch combinators[i - 1] {
        case .descendant:
            var p = node.parent
            while let parent = p {
                if match(i - 1, parent, anchor: anchor) { return true }
                p = parent.parent
            }
            return false
        case .child:
            return node.parent.map { match(i - 1, $0, anchor: anchor) } ?? false
        case .next:
            return node.previousSiblings.first.map { match(i - 1, $0, anchor: anchor) } ?? false
        case .subsequent:
            return node.previousSiblings.contains { match(i - 1, $0, anchor: anchor) }
        }
    }

    private func matches(_ node: Node, relativeTo anchor: Node) -> Bool {
        match(compounds.count - 1, node, anchor: anchor)
    }

    private static func test(_ s: Simple, _ n: Node) -> Bool {
        switch s {
        case .universal: return true
        case .cls(let c): return n.classes.contains(c)
        case .attribute(let name, let op, let value):
            guard let v = n.attributes[name] else { return false }
            switch op {
            case "=":  return v == value
            case "$=": return v.hasSuffix(value)
            case "^=": return v.hasPrefix(value)
            case "*=": return v.contains(value)
            default:   return true
            }
        case .not(let list): return !list.contains { $0.matches(n) }
        case .is(let list):  return list.contains { $0.matches(n) }
        case .has(let list):
            let scope = n.descendants + n.nextSiblings.flatMap { [$0] + $0.descendants }
            return list.contains { sel in scope.contains { sel.matches($0, relativeTo: n) } }
        case .only:
            return n.siblings.count == 1
        case .nth(let a, let b, let fromEnd):
            let i = n.index
            let position = fromEnd ? n.siblings.count - i : i + 1
            if a == 0 { return position == b }
            let k = (position - b)
            return k % a == 0 && k / a >= 0
        }
    }
}

enum SelectorParser {
    /// nil for anything only reachable by hovering, which a TV can't do.
    static func parse(_ text: String) -> Selector? {
        var p = Cursor(Array(text))
        return p.selector()
    }

    private struct Cursor {
        let chars: [Character]
        var i = 0

        init(_ chars: [Character]) { self.chars = chars }

        var done: Bool { i >= chars.count }
        var peek: Character? { done ? nil : chars[i] }

        mutating func skipSpace() -> Bool {
            var moved = false
            while let c = peek, c.isWhitespace { i += 1; moved = true }
            return moved
        }

        mutating func name() -> String {
            var out = ""
            while let c = peek, c.isLetter || c.isNumber || c == "-" || c == "_" {
                out.append(c)
                i += 1
            }
            return out
        }

        /// The text inside the brackets just opened.
        mutating func bracketed() -> String {
            var depth = 1
            var out = ""
            while let c = peek {
                i += 1
                if c == "(" { depth += 1 }
                if c == ")" { depth -= 1; if depth == 0 { break } }
                out.append(c)
            }
            return out
        }

        mutating func selector() -> Selector? {
            var s = Selector()
            _ = skipSpace()
            if let c = peek, let lead = Self.combinator(c) {
                s.leading = lead
                i += 1
                _ = skipSpace()
            }
            while !done {
                var compound = Compound()
                while let c = peek, !c.isWhitespace, Self.combinator(c) == nil {
                    switch c {
                    case ".":
                        i += 1
                        compound.simples.append(.cls(name()))
                    case "*":
                        i += 1
                        compound.simples.append(.universal)
                    case "[":
                        i += 1
                        var body = ""
                        while let b = peek, b != "]" { body.append(b); i += 1 }
                        i += 1
                        compound.simples.append(Self.attribute(body))
                    case ":":
                        i += 1
                        let isElement = peek == ":"
                        if isElement { i += 1 }
                        let pseudo = name()
                        if pseudo == "before" || pseudo == "after" {
                            s.pseudoElement = pseudo
                            break
                        }
                        if isElement { return nil }
                        var args = ""
                        if peek == "(" { i += 1; args = bracketed() }
                        guard let simple = Self.pseudo(pseudo, args) else { return nil }
                        compound.simples.append(simple)
                    default:
                        // A tag name. Everything on the page is matched by class.
                        let tag = name()
                        if tag.isEmpty { return nil }
                        compound.simples.append(.universal)
                    }
                }
                s.compounds.append(compound)
                let spaced = skipSpace()
                guard let c = peek else { break }
                if let comb = Self.combinator(c) {
                    i += 1
                    _ = skipSpace()
                    s.combinators.append(comb)
                } else if spaced {
                    s.combinators.append(.descendant)
                }
            }
            return s.compounds.isEmpty ? nil : s
        }

        private static func combinator(_ c: Character) -> Combinator? {
            switch c {
            case ">": return .child
            case "+": return .next
            case "~": return .subsequent
            default:  return nil
            }
        }

        private static func attribute(_ body: String) -> Simple {
            for op in ["$=", "^=", "*=", "="] {
                if let r = body.range(of: op) {
                    let value = body[r.upperBound...]
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                    return .attribute(name: String(body[..<r.lowerBound]), op: op, value: value)
                }
            }
            return .attribute(name: body, op: "", value: "")
        }

        private static func list(_ args: String) -> [Selector] {
            splitTopLevel(args, on: ",").compactMap(SelectorParser.parse)
        }

        private static func pseudo(_ name: String, _ args: String) -> Simple? {
            switch name {
            case "hover":                       return nil
            case "not":
                let parts = splitTopLevel(args, on: ",")
                let parsed = parts.compactMap(SelectorParser.parse)
                return .not(parsed)
            case "is", "where":
                let parsed = list(args)
                return parsed.isEmpty ? nil : .is(parsed)
            case "has":
                let parsed = list(args)
                return parsed.isEmpty ? nil : .has(parsed)
            // Everything sits in `.text` as the same element, so "of type" and
            // plain child counting agree.
            case "first-child", "first-of-type":        return .nth(a: 0, b: 1, fromEnd: false)
            case "last-child", "last-of-type":          return .nth(a: 0, b: 1, fromEnd: true)
            case "only-child", "only-of-type":          return .only
            case "nth-child", "nth-of-type":            return nth(args, fromEnd: false)
            case "nth-last-child", "nth-last-of-type":  return nth(args, fromEnd: true)
            default:                                    return nil
            }
        }

        private static func nth(_ args: String, fromEnd: Bool) -> Simple {
            let v = args.replacingOccurrences(of: " ", with: "")
            if v == "odd" { return .nth(a: 2, b: 1, fromEnd: fromEnd) }
            if v == "even" { return .nth(a: 2, b: 0, fromEnd: fromEnd) }
            if let n = v.firstIndex(of: "n") {
                let a = v[..<n]
                let step = a.isEmpty ? 1 : a == "-" ? -1 : Int(a) ?? 1
                return .nth(a: step, b: Int(v[v.index(after: n)...]) ?? 0, fromEnd: fromEnd)
            }
            return .nth(a: 0, b: Int(v) ?? 1, fromEnd: fromEnd)
        }
    }
}

/// CSS value parsing the renderer needs.
public enum EmoteValues {
    public static func px(_ value: String?) -> Double? { CSS.px(value) }
}

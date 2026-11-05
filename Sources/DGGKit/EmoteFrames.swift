import Foundation

/// Animated DGG emotes ship as ONE horizontal sprite sheet, not a GIF.
/// `catJAM` is 7144x30 — 188 frames of 38px. Rendering the sheet as a single
/// inline image produced a filmstrip thousands of points wide that overflowed
/// the chat rail and drew across the video.
///
/// The frame count lives in the site's CSS:
///   `.emote.catJAM { width: 38px; animation: catJAM-anim 2 steps(188) 6.5s; }`
public enum EmoteFrames {

    /// Derives the stylesheet URL from an emote image URL, since both are
    /// versioned together (…/4.68.0/emotes/…).
    public static func stylesheetURL(fromImage url: String) -> URL? {
        guard let i = url.range(of: "/emotes/") else { return nil }
        return URL(string: url[url.startIndex..<i.upperBound] + "emotes.css")
    }

    /// Every rule for an emote, with its full selector, so conditional ones
    /// can be discarded. Rules WITHOUT steps() matter too: a static emote can
    /// still declare a display width smaller than its image, hiding a secret
    /// variant in the remaining pixels (WWWWaiting is 77px holding a 36px
    /// emote). Only matching steps() rules meant drawing the whole image.
    private static let pattern = try! NSRegularExpression(
        pattern: #"([^{}]*)\.emote\.([A-Za-z0-9_-]+)([^{]*)\{([^}]*)\}"#,
        options: [.dotMatchesLineSeparators]
    )
    private static let widthPattern = try! NSRegularExpression(
        pattern: #"width:\s*(\d+)px"#
    )
    private static let stepsPattern = try! NSRegularExpression(
        pattern: #"steps\((\d+)\)"#
    )
    private static let startPattern = try! NSRegularExpression(
        pattern: #"--start:\s*(-?\d+)px"#
    )
    private static let positionPattern = try! NSRegularExpression(
        pattern: #"background-position:\s*(-?\d+)px"#
    )
    private static let endPattern = try! NSRegularExpression(
        pattern: #"--end:\s*(-?\d+)px"#
    )
    /// First positive time in the animation shorthand is the duration;
    /// later ones are delays (sometimes negative, e.g. `-.67s`).
    private static let durationPattern = try! NSRegularExpression(
        pattern: #"animation:[^;}]*?(?<![\d.-])(\d*\.?\d+)s"#
    )

    public struct Sprite: Sendable {
        /// Frame width declared in the animation rule, if present.
        public let declaredWidth: Int?
        /// Frame count from steps(). 1 means it does not animate.
        public let steps: Int
        /// Pixel offset of frame 0. Some sheets hold more than the animation
        /// uses — BINGQILIN animates 0..2880 of a 6390px sheet, the rest
        /// being an alternate variant.
        public let startPx: Int
        /// Resting frame offset, used when the emote does not animate.
        public let restPx: Int?
        /// End of the animated run, when the stylesheet declares one.
        public let endPx: Int?
        /// Duration of one cycle, from the animation shorthand.
        public let duration: Double?

        /// Frames per second this emote is meant to play at. catJAM is
        /// steps(188) over 6.5s — about 29fps, not the flat rate we assumed.
        public var fps: Double {
            guard steps > 1, let d = duration, d > 0 else { return 15 }
            return min(60, max(1, Double(steps) / d))
        }

        public var animates: Bool { steps > 1 }
    }

    /// prefix -> sprite description.
    ///
    /// Both sources disagree for some emotes: NAILS' steps divide to 32.2px
    /// while its declared width is exact, and BINGQILIN is the reverse. The
    /// caller knows the real sheet width, so it picks whichever divides it.
    public static func parse(css: String) -> [String: Sprite] {
        let ns = css as NSString
        var out: [String: Sprite] = [:]

        for m in pattern.matches(in: css,
                                 range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges >= 5 else { continue }
            let before = ns.substring(with: m.range(at: 1))
            let name = ns.substring(with: m.range(at: 2))
            let after = ns.substring(with: m.range(at: 3))
            let block = ns.substring(with: m.range(at: 4))

            // Conditional rules describe OTHER people's view of the emote:
            // per-user variants, fusion pairs, hover states. Not the default.
            let selector = before + after
            let conditional = ["[data-username", ":has(", "::before", "::after",
                               ":hover", "+ ."]
            if conditional.contains(where: selector.contains) { continue }

            let bns = block as NSString
            let full = NSRange(location: 0, length: bns.length)
            func px(_ re: NSRegularExpression) -> Int? {
                guard let mm = re.firstMatch(in: block, range: full) else { return nil }
                return Int(bns.substring(with: mm.range(at: 1))).map(abs)
            }

            let width = px(widthPattern)
            var steps = 1
            if let st = stepsPattern.firstMatch(in: block, range: full) {
                steps = Int(bns.substring(with: st.range(at: 1))) ?? 1
            }
            let start = px(startPattern)
            let end = px(endPattern)
            let rest = px(positionPattern)
            var duration: Double?
            if let dm = durationPattern.firstMatch(in: block, range: full) {
                duration = Double(bns.substring(with: dm.range(at: 1)))
            }

            let prior = out[name]
            // The declaration carrying the image also states the FULL size;
            // a later, smaller width is the one actually displayed.
            let mergedWidth: Int?
            switch (width, prior?.declaredWidth) {
            case (let w?, let p?): mergedWidth = min(w, p)
            case (let w?, nil):    mergedWidth = w
            case (nil, let p):     mergedWidth = p
            }

            out[name] = Sprite(declaredWidth: mergedWidth,
                               steps: max(steps, prior?.steps ?? 1),
                               startPx: start ?? prior?.startPx ?? 0,
                               restPx: rest ?? prior?.restPx,
                               endPx: end ?? prior?.endPx,
                               duration: duration ?? prior?.duration)
        }
        return out
    }

    /// Derive the frame width from the animated RUN rather than either source
    /// alone, because the two disagree in different directions:
    ///   - BINGQILIN declares --end, animating 0..2880 of a 6390px sheet
    ///   - RaveDoge declares no end, so its run is the whole 2700px sheet and
    ///     its declared width (50) is half the real frame (100)
    ///   - NAILS' steps are off by one, so the declared width wins there
    public static func frameWidth(for sprite: Sprite, sheetWidth: Int) -> Int? {
        let runEnd = sprite.endPx ?? sheetWidth
        let run = runEnd - sprite.startPx
        if sprite.steps > 1, run > 0, run % sprite.steps == 0 {
            return run / sprite.steps
        }
        if let w = sprite.declaredWidth, w > 0, w <= sheetWidth { return w }
        if sprite.steps > 1, run > 0 { return max(1, run / sprite.steps) }
        return nil
    }

    public static func load(anyEmoteImageURL: String) async -> [String: Sprite] {
        guard let url = stylesheetURL(fromImage: anyEmoteImageURL),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let css = String(data: data, encoding: .utf8)
        else { return [:] }
        return parse(css: css)
    }
}

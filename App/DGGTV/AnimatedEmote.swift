import UIKit
import DGGKit

/// Emotes are drawn as Core Animation layers placed over the text, not as part
/// of it. Each layer plays on the GPU by itself, so there's no timer, nothing
/// redraws, and an emote keeps running however fast chat moves. Going through
/// the text system instead is what made animated emotes flash and vanish.

/// A file's pixels. Animated files are unpacked into one atlas, so a frame
/// change is just looking at a different part of an image already on the GPU.
final class EmoteAsset {
    let image: CGImage
    /// Empty for ordinary images.
    let frames: [CGRect]
    let delays: [Double]
    /// 0 means forever.
    let loops: Int

    init(image: CGImage, frames: [CGRect] = [], delays: [Double] = [], loops: Int = 0) {
        self.image = image
        self.frames = frames
        self.delays = delays
        self.loops = loops
    }

    var width: CGFloat { frames.first?.width ?? CGFloat(image.width) }
    var height: CGFloat { frames.first?.height ?? CGFloat(image.height) }

    static func decode(_ data: Data) -> EmoteAsset? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let n = CGImageSourceGetCount(src)
        guard n > 1 else {
            return CGImageSourceCreateImageAtIndex(src, 0, nil).map { EmoteAsset(image: $0) }
        }
        var images: [CGImage] = []
        var delays: [Double] = []
        for i in 0..<n {
            guard let f = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            images.append(f)
            delays.append(delay(src, i))
        }
        guard let first = images.first else { return nil }

        let w = first.width
        let h = first.height
        let columns = max(1, min(images.count, 8192 / max(1, w)))
        let rows = (images.count + columns - 1) / columns
        guard let ctx = CGContext(data: nil, width: columns * w, height: rows * h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        var rects: [CGRect] = []
        for (i, f) in images.enumerated() {
            let x = (i % columns) * w
            let y = (i / columns) * h
            // A bitmap context counts from the bottom; layers from the top.
            ctx.draw(f, in: CGRect(x: x, y: rows * h - y - h, width: w, height: h))
            rects.append(CGRect(x: x, y: y, width: w, height: h))
        }
        guard let atlas = ctx.makeImage() else { return nil }
        return EmoteAsset(image: atlas, frames: rects, delays: delays, loops: loopCount(src))
    }

    private static func delay(_ src: CGImageSource, _ i: Int) -> Double {
        guard let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
        else { return 0.1 }
        let sets: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
        ]
        for (dict, unclamped, clamped) in sets {
            guard let d = p[dict] as? [CFString: Any] else { continue }
            let v = (d[unclamped] as? Double) ?? (d[clamped] as? Double) ?? 0
            // Browsers treat near-zero delays as 0.1s, and art relies on it.
            return v < 0.02 ? 0.1 : v
        }
        return 0.1
    }

    private static func loopCount(_ src: CGImageSource) -> Int {
        guard let p = CGImageSourceCopyProperties(src, nil) as? [CFString: Any] else { return 0 }
        if let d = p[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            return d[kCGImagePropertyGIFLoopCount] as? Int ?? 1
        }
        if let d = p[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            return d[kCGImagePropertyAPNGLoopCount] as? Int ?? 0
        }
        return 0
    }
}

/// One emote: its box in the line, with the drawn parts inside.
final class EmoteLayer: CALayer {
    let look: EmoteLook
    let scale: CGFloat

    @MainActor
    init(look: EmoteLook, scale: CGFloat, store: EmoteImageStore) {
        self.look = look
        self.scale = scale
        super.init()
        let h = CGFloat(look.base.height) * scale
        bounds = CGRect(x: 0, y: 0, width: CGFloat(look.advance) * scale, height: h)
        addPart(look.base, origin: CGPoint(x: CGFloat(look.marginLeft) * scale, y: 0), store: store)
        for extra in look.extras {
            addPart(extra, origin: CGPoint(x: CGFloat(look.marginLeft + extra.left) * scale,
                                           y: CGFloat(extra.top) * scale), store: store)
        }
    }

    override init(layer: Any) {
        let other = layer as! EmoteLayer
        look = other.look
        scale = other.scale
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    @MainActor
    private func addPart(_ part: EmotePart, origin: CGPoint, store: EmoteImageStore) {
        guard let url = part.image else { return }
        let l = CALayer()
        l.contentsGravity = .resize
        l.opacity = Float(part.opacity)
        let size = CGSize(width: CGFloat(part.drawnWidth) * scale,
                          height: CGFloat(part.height) * scale)
        l.bounds = CGRect(origin: .zero, size: size)
        l.anchorPoint = Self.anchor(part.origin)
        l.position = CGPoint(x: origin.x + CGFloat(part.drawnOffset) * scale
                                + size.width * l.anchorPoint.x,
                             y: origin.y + size.height * l.anchorPoint.y)
        let box = size
        if let t = part.transform { l.transform = Self.transform(t, box: box, scale: scale) }
        addSublayer(l)
        store.asset(url) { [weak self, weak l] asset in
            guard let self, let l else { return }
            self.configure(l, part: part, asset: asset)
        }
    }

    private func configure(_ l: CALayer, part: EmotePart, asset: EmoteAsset) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        l.contents = asset.image

        let imageW = CGFloat(asset.image.width)
        let imageH = CGFloat(asset.image.height)
        func rect(_ x: CGFloat) -> CGRect {
            var px = x.truncatingRemainder(dividingBy: imageW)
            if px < 0 { px += imageW }
            let w = min(CGFloat(part.drawnWidth), imageW - px)
            return CGRect(x: px / imageW, y: 0, width: w / imageW,
                          height: min(1, CGFloat(part.height) / imageH))
        }

        if asset.frames.isEmpty {
            l.contentsRect = rect(CGFloat(part.backgroundX))
        } else {
            let normal = asset.frames.map {
                CGRect(x: $0.minX / imageW, y: $0.minY / imageH,
                       width: $0.width / imageW, height: $0.height / imageH)
            }
            l.contentsRect = normal[0]
            play(file: normal, delays: asset.delays, loops: asset.loops, on: l)
        }

        for (i, a) in part.animations.enumerated() {
            for (key, animation) in Self.animations(a, part: part, box: l.bounds.size,
                                                    scale: scale, rect: rect) {
                begin(animation, a, key: "\(key)\(i)", on: l)
            }
        }
    }

    private func play(file rects: [CGRect], delays: [Double], loops: Int, on l: CALayer) {
        let total = delays.reduce(0, +)
        guard total > 0 else { return }
        let a = CAKeyframeAnimation(keyPath: "contentsRect")
        a.values = rects.map { NSValue(cgRect: $0) }
        var at = 0.0
        var times: [NSNumber] = []
        for d in delays {
            times.append(NSNumber(value: at / total))
            at += d
        }
        times.append(1)
        a.keyTimes = times
        a.calculationMode = .discrete
        a.duration = total
        a.repeatCount = loops == 0 ? .infinity : Float(loops)
        // Files that play once rest on their last frame.
        a.fillMode = .forwards
        a.isRemovedOnCompletion = false
        l.add(a, forKey: "file")
    }

    private func begin(_ c: CAKeyframeAnimation, _ a: EmoteAnimation, key: String, on l: CALayer) {
        c.duration = max(0.01, a.duration)
        // A finite repeat that doesn't hold its last frame just stops dead on
        // the site. Here it keeps going, so catJAM stays dancing while visible.
        let repeats = a.iterations > 1 && !a.holdsEnd
        c.repeatCount = repeats || a.iterations == .infinity ? .infinity : Float(a.iterations)
        c.autoreverses = a.alternates
        if a.delay > 0 {
            c.beginTime = l.convertTime(CACurrentMediaTime(), from: nil) + a.delay
            c.fillMode = .backwards
        } else if a.delay < 0 {
            c.timeOffset = -a.delay
        }
        if a.holdsEnd {
            c.fillMode = a.delay > 0 ? .both : .forwards
            c.isRemovedOnCompletion = false
        }
        l.add(c, forKey: key)
    }

    // MARK: - CSS to Core Animation

    private static func animations(_ a: EmoteAnimation, part: EmotePart, box: CGSize, scale: CGFloat,
                                   rect: (CGFloat) -> CGRect) -> [(String, CAKeyframeAnimation)] {
        var out: [(String, CAKeyframeAnimation)] = []

        if a.keyframes.contains(where: { $0.properties["background-position"] != nil }) {
            let keys = track(a, "background-position", base: part.backgroundX) {
                EmoteValues.px($0).map { -$0 }
            }
            let n = max(1, a.steps ?? 30)
            let c = CAKeyframeAnimation(keyPath: "contentsRect")
            c.values = (0..<n).map { i in
                NSValue(cgRect: rect(CGFloat(value(at: Double(i) / Double(n), in: keys))))
            }
            c.keyTimes = (0...n).map { NSNumber(value: Double($0) / Double(n)) }
            c.calculationMode = .discrete
            out.append(("bg", c))
        }

        if a.keyframes.contains(where: { $0.properties["transform"] != nil }) {
            let frames = a.keyframes.filter { $0.properties["transform"] != nil }
            let c = CAKeyframeAnimation(keyPath: "transform")
            var values = frames.map {
                NSValue(caTransform3D: transform($0.properties["transform"] ?? "", box: box, scale: scale))
            }
            var times = frames.map { NSNumber(value: $0.offset) }
            let rest = NSValue(caTransform3D: transform(part.transform ?? "", box: box, scale: scale))
            if frames.first?.offset != 0 { values.insert(rest, at: 0); times.insert(0, at: 0) }
            if frames.last?.offset != 1 { values.append(rest); times.append(1) }
            c.values = values
            c.keyTimes = times
            c.timingFunction = timing(a.timing)
            out.append(("transform", c))
        }

        if a.keyframes.contains(where: { $0.properties["opacity"] != nil }) {
            let keys = track(a, "opacity", base: part.opacity) { Double($0 ?? "") }
            let c = CAKeyframeAnimation(keyPath: "opacity")
            c.values = keys.map(\.value)
            c.keyTimes = keys.map { NSNumber(value: $0.offset) }
            c.timingFunction = timing(a.timing)
            out.append(("opacity", c))
        }

        for (property, path) in [("left", "position.x"), ("top", "position.y")]
        where a.keyframes.contains(where: { $0.properties[property] != nil }) {
            let keys = track(a, property, base: 0) { EmoteValues.px($0) }
            let c = CAKeyframeAnimation(keyPath: path)
            c.values = keys.map { $0.value * Double(scale) }
            c.keyTimes = keys.map { NSNumber(value: $0.offset) }
            c.isAdditive = true
            c.timingFunction = timing(a.timing)
            out.append((property, c))
        }
        return out
    }

    /// A numeric property's keyframes, with its resting value filling any gap
    /// at the ends, which is what CSS does.
    private static func track(_ a: EmoteAnimation, _ property: String, base: Double,
                              parse: (String?) -> Double?) -> [(offset: Double, value: Double)] {
        var keys = a.keyframes.compactMap { f in
            parse(f.properties[property]).map { (offset: f.offset, value: $0) }
        }
        if keys.first?.offset != 0 { keys.insert((0, base), at: 0) }
        if keys.last?.offset != 1 { keys.append((1, base)) }
        return keys
    }

    private static func value(at t: Double, in keys: [(offset: Double, value: Double)]) -> Double {
        guard var previous = keys.first else { return 0 }
        for key in keys {
            if t <= key.offset {
                let span = key.offset - previous.offset
                guard span > 0 else { return key.value }
                return previous.value + (key.value - previous.value) * (t - previous.offset) / span
            }
            previous = key
        }
        return previous.value
    }

    private static func timing(_ name: String) -> CAMediaTimingFunction {
        switch name {
        case "linear":      return .init(name: .linear)
        case "ease-in":     return .init(name: .easeIn)
        case "ease-out":    return .init(name: .easeOut)
        case "ease-in-out": return .init(name: .easeInEaseOut)
        default:
            if name.hasPrefix("cubic-bezier(") {
                let n = name.dropFirst(13).dropLast().split(separator: ",")
                    .compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
                if n.count == 4 {
                    return .init(controlPoints: n[0], n[1], n[2], n[3])
                }
            }
            return .init(name: .default)
        }
    }

    private static func anchor(_ origin: String?) -> CGPoint {
        guard let origin else { return CGPoint(x: 0.5, y: 0.5) }
        var out = CGPoint(x: 0.5, y: 0.5)
        let parts = origin.split(separator: " ").map(String.init)
        for (i, p) in parts.prefix(2).enumerated() {
            let v: CGFloat?
            switch p {
            case "left", "top":     v = 0
            case "right", "bottom": v = 1
            case "center":          v = 0.5
            default:
                v = p.hasSuffix("%") ? Double(p.dropLast()).map { CGFloat($0) / 100 } : nil
            }
            guard let v else { continue }
            let horizontal = p == "top" || p == "bottom" ? false
                : p == "left" || p == "right" ? true : i == 0
            if horizontal { out.x = v } else { out.y = v }
        }
        return out
    }

    /// Applies each function in order, as CSS does.
    static func transform(_ text: String, box: CGSize, scale: CGFloat) -> CATransform3D {
        var t = CATransform3DIdentity
        let pattern = try? NSRegularExpression(pattern: #"([a-zA-Z0-9]+)\(([^)]*)\)"#)
        let ns = text as NSString
        for m in pattern?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? [] {
            let name = ns.substring(with: m.range(at: 1))
            let args = ns.substring(with: m.range(at: 2))
                .split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
            func length(_ s: String?, _ axis: CGFloat) -> CGFloat {
                guard let s else { return 0 }
                if s.hasSuffix("%") { return CGFloat(Double(s.dropLast()) ?? 0) / 100 * axis }
                return CGFloat(Double(s.replacingOccurrences(of: "px", with: "")) ?? 0) * scale
            }
            func angle(_ s: String?) -> CGFloat {
                guard let s else { return 0 }
                if s.hasSuffix("deg") { return CGFloat(Double(s.dropLast(3)) ?? 0) * .pi / 180 }
                if s.hasSuffix("turn") { return CGFloat(Double(s.dropLast(4)) ?? 0) * 2 * .pi }
                if s.hasSuffix("rad") { return CGFloat(Double(s.dropLast(3)) ?? 0) }
                return 0
            }
            func number(_ s: String?, _ fallback: CGFloat) -> CGFloat {
                s.flatMap(Double.init).map { CGFloat($0) } ?? fallback
            }
            switch name {
            case "translate":
                t = CATransform3DTranslate(t, length(args.first, box.width),
                                           length(args.count > 1 ? args[1] : nil, box.height), 0)
            case "translateX": t = CATransform3DTranslate(t, length(args.first, box.width), 0, 0)
            case "translateY": t = CATransform3DTranslate(t, 0, length(args.first, box.height), 0)
            case "scale":
                let x = number(args.first, 1)
                t = CATransform3DScale(t, x, number(args.count > 1 ? args[1] : nil, x), 1)
            case "scaleX": t = CATransform3DScale(t, number(args.first, 1), 1, 1)
            case "scaleY": t = CATransform3DScale(t, 1, number(args.first, 1), 1)
            case "rotate": t = CATransform3DRotate(t, angle(args.first), 0, 0, 1)
            case "skew", "skewX":
                var s = CATransform3DIdentity
                s.m21 = tan(angle(args.first))
                if args.count > 1 { s.m12 = tan(angle(args[1])) }
                t = CATransform3DConcat(s, t)
            default: break
            }
        }
        return t
    }
}

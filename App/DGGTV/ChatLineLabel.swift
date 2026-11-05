import SwiftUI
import UIKit
import DGGKit

/// Chat line rendered through UIKit text layout.
///
/// SwiftUI's `Text(Image(uiImage:))` concatenation does NOT keep inline images
/// inside their container on tvOS — emotes escaped the chat rail and drew over
/// the video. NSTextAttachment lays them out correctly, wraps properly, and is
/// cheaper at ~400 messages a minute.
struct ChatLineLabel: UIViewRepresentable {

    let attributed: NSAttributedString
    let width: CGFloat

    func makeUIView(context: Context) -> ChatTextView {
        // TextKit 1, which reports where each glyph landed so emote layers can
        // be placed over them. Built by hand because the convenient
        // `init(usingTextLayoutManager:)` skips Swift's stored properties in a
        // subclass, which crashes on first use.
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: CGSize(width: width,
                                                     height: .greatestFiniteMagnitude))
        manager.addTextContainer(container)
        let v = ChatTextView(frame: .zero, textContainer: container)
        // isEditable does not exist on tvOS — text views are read-only there.
        v.isScrollEnabled = false
        v.isSelectable = false
        v.backgroundColor = .clear
        v.textContainerInset = .zero
        v.textContainer.lineFragmentPadding = 0
        return v
    }

    func updateUIView(_ v: ChatTextView, context: Context) {
        v.textContainer.size.width = width
        v.apply(attributed)
    }

    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView: ChatTextView,
                      context: Context) -> CGSize? {
        let w = proposal.width ?? width
        let fit = uiView.sizeThatFits(CGSize(width: w,
                                             height: .greatestFiniteMagnitude))
        return CGSize(width: w, height: ceil(fit.height))
    }
}

extension NSAttributedString.Key {
    static let emote = NSAttributedString.Key("dggEmote")
    static let rainbow = NSAttributedString.Key("dggRainbow")
}

/// What to draw in the space left for an emote.
final class EmoteRun: NSObject {
    let look: EmoteLook
    let scale: CGFloat
    let store: EmoteImageStore

    init(look: EmoteLook, scale: CGFloat, store: EmoteImageStore) {
        self.look = look
        self.scale = scale
        self.store = store
    }
}

/// Text with emotes and rainbow names laid over it.
final class ChatTextView: UITextView {
    private var overlays: [(range: NSRange, layer: CALayer)] = []
    private var applied: NSAttributedString?
    private var placedWidth: CGFloat = -1

    func apply(_ s: NSAttributedString) {
        // Identity check: rebuilding the layers would restart their animations.
        guard applied !== s else { return }
        applied = s
        attributedText = s

        overlays.forEach { $0.layer.removeFromSuperlayer() }
        overlays = []
        let all = NSRange(location: 0, length: s.length)
        s.enumerateAttribute(.emote, in: all) { value, range, _ in
            guard let run = value as? EmoteRun else { return }
            let l = EmoteLayer(look: run.look, scale: run.scale, store: run.store)
            layer.addSublayer(l)
            overlays.append((range, l))
        }
        s.enumerateAttribute(.rainbow, in: all) { value, range, _ in
            guard value != nil else { return }
            let l = RainbowNameLayer(text: s.attributedSubstring(from: range))
            layer.addSublayer(l)
            overlays.append((range, l))
        }
        placedWidth = -1
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !overlays.isEmpty, placedWidth != bounds.width else { return }
        placedWidth = bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutManager.ensureLayout(for: textContainer)
        for (range, l) in overlays {
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let r = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            l.position = CGPoint(x: r.midX, y: r.midY)
        }
        CATransaction.commit()
    }
}

/// A T5 name: a rainbow sliding along behind the letters.
final class RainbowNameLayer: CALayer {
    private static let period: CGFloat = 260

    init(text: NSAttributedString) {
        super.init()
        let opaque = NSMutableAttributedString(attributedString: text)
        opaque.addAttribute(.foregroundColor, value: UIColor.white,
                            range: NSRange(location: 0, length: opaque.length))
        let size = opaque.size()
        bounds = CGRect(origin: .zero, size: size)

        let mask = CALayer()
        mask.frame = bounds
        mask.contents = UIGraphicsImageRenderer(size: size).image { _ in
            opaque.draw(at: .zero)
        }.cgImage
        mask.contentsScale = UIScreen.main.scale
        self.mask = mask

        // Drawn once into a strip that repeats every period, so sliding it by
        // exactly one period loops with no visible seam.
        let cycles = Int(ceil(size.width / Self.period)) + 1
        let stripSize = CGSize(width: CGFloat(cycles) * Self.period, height: max(1, size.height))
        let colors = [(1.0, 0.25, 0.25), (1.0, 0.65, 0.1), (1.0, 0.95, 0.2),
                      (0.3, 0.9, 0.35), (0.3, 0.6, 1.0), (0.75, 0.35, 1.0), (1.0, 0.25, 0.25)]
            .map { CGColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) }
        let strip = UIGraphicsImageRenderer(size: stripSize).image { ctx in
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                            colors: colors as CFArray, locations: nil) else { return }
            for i in 0..<cycles {
                let x = CGFloat(i) * Self.period
                ctx.cgContext.saveGState()
                ctx.cgContext.clip(to: CGRect(x: x, y: 0, width: Self.period, height: stripSize.height))
                ctx.cgContext.drawLinearGradient(gradient, start: CGPoint(x: x, y: 0),
                                                 end: CGPoint(x: x + Self.period, y: 0), options: [])
                ctx.cgContext.restoreGState()
            }
        }
        let band = CALayer()
        band.contents = strip.cgImage
        band.anchorPoint = .zero
        band.bounds = CGRect(origin: .zero, size: stripSize)
        band.position = .zero
        addSublayer(band)

        let slide = CABasicAnimation(keyPath: "position.x")
        slide.fromValue = -Self.period
        slide.toValue = 0
        slide.duration = 3
        slide.repeatCount = .infinity
        band.add(slide, forKey: "flow")
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("not supported") }
}

/// A lone emote outside a text line, for combos.
struct EmoteView: UIViewRepresentable {
    let look: EmoteLook
    let scale: CGFloat
    let store: EmoteImageStore

    func makeUIView(context: Context) -> Host { Host() }

    func updateUIView(_ v: Host, context: Context) {
        v.show(look, scale: scale, store: store)
    }

    final class Host: UIView {
        private var shown: EmoteLayer?

        func show(_ look: EmoteLook, scale: CGFloat, store: EmoteImageStore) {
            // Same art: leave it running through count changes.
            if let shown, shown.look.base.image == look.base.image,
               shown.look.base.width == look.base.width, shown.scale == scale { return }
            shown?.removeFromSuperlayer()
            let l = EmoteLayer(look: look, scale: scale, store: store)
            layer.addSublayer(l)
            shown = l
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shown?.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }
    }
}

enum ChatText {
    /// Driven by the font-size setting; rows are rebuilt on every render so a
    /// change takes effect immediately.
    static var size: CGFloat = 21

    static var font: UIFont { .systemFont(ofSize: size) }
    static var bold: UIFont { .systemFont(ofSize: size, weight: .bold) }
    static var emoteHeight: CGFloat { size * 1.25 }

    /// Pinning the line height keeps rows evenly spaced. Without it an emote
    /// attachment is taller than the text and that single line grows, so
    /// messages with emotes sat further apart than plain ones.
    static var paragraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        let h = (size * 1.62).rounded()
        p.minimumLineHeight = h
        p.maximumLineHeight = h
        p.lineBreakMode = .byWordWrapping
        return p
    }

    /// Heights in the stylesheet assume about 30px emotes.
    static var emoteScale: CGFloat { emoteHeight / 30 }

    private static let blank = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        .image { _ in }

    /// Leaves a gap the right size. The emote itself is a layer over the text.
    static func emote(_ look: EmoteLook, store: EmoteImageStore) -> NSAttributedString {
        let a = NSTextAttachment()
        a.image = blank
        let scale = emoteScale
        a.bounds = CGRect(x: 0, y: -emoteHeight * 0.19,
                          width: CGFloat(look.advance) * scale, height: emoteHeight)
        let str = NSMutableAttributedString(attachment: a)
        let all = NSRange(location: 0, length: str.length)
        str.addAttribute(.paragraphStyle, value: Self.paragraph, range: all)
        str.addAttribute(.emote, value: EmoteRun(look: look, scale: scale, store: store), range: all)
        return str
    }

    /// Drawn clear, with the rainbow layer showing through in its place.
    static func rainbowNick(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: Self.bold,
            .foregroundColor: UIColor.clear,
            .paragraphStyle: Self.paragraph,
            .rainbow: true,
        ])
    }

    /// An image sitting on the text baseline, scaled to the line.
    static func attachment(_ image: UIImage, height: CGFloat? = nil) -> NSAttributedString {
        let a = NSTextAttachment()
        a.image = image
        let height = height ?? emoteHeight
        let w = image.size.height > 0 ? image.size.width * (height / image.size.height) : height
        // Nudge down so the glyph sits optically centred on the baseline.
        a.bounds = CGRect(x: 0, y: -height * 0.19, width: w, height: height)
        let str = NSMutableAttributedString(attachment: a)
        str.addAttribute(.paragraphStyle, value: Self.paragraph,
                         range: NSRange(location: 0, length: str.length))
        return str
    }

    static func plain(_ s: String, _ color: UIColor, bold: Bool = false) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: bold ? Self.bold : Self.font,
            .foregroundColor: color,
            .paragraphStyle: Self.paragraph,
        ])
    }

    private static let links = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func isLink(_ word: String) -> Bool {
        guard word.contains("."), word.count > 3 else { return false }
        let all = NSRange(location: 0, length: (word as NSString).length)
        return links?.firstMatch(in: word, range: all) != nil
    }

    /// Can't be followed from a TV, but should read as a link so nobody tries
    /// to read one as a message.
    static func link(_ s: String) -> NSAttributedString {
        let color = UIColor(red: 0.42, green: 0.72, blue: 1, alpha: 1)
        return NSAttributedString(string: s, attributes: [
            .font: Self.font,
            .foregroundColor: color,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: color,
            .paragraphStyle: Self.paragraph,
        ])
    }

    static func uiColor(hex: String?) -> UIColor {
        guard var h = hex?.trimmingCharacters(in: .whitespaces), !h.isEmpty else {
            return UIColor.white.withAlphaComponent(0.78)
        }
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else {
            return UIColor.white.withAlphaComponent(0.78)
        }
        return UIColor(red: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

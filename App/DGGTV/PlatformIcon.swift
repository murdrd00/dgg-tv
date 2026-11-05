import SwiftUI
import DGGKit

/// The real platform marks, as vectors.
///
/// SF Symbols has no brand glyphs, so `bolt` / `gamecontroller` were standing
/// in for Kick and Twitch and read as generic. These are the actual logo paths
/// taken from destiny.gg's own inline SVG templates (24x24 viewBox).
struct PlatformIcon: View {
    let platform: EmbedRef.Platform

    var body: some View {
        switch platform {
        case .youtube:
            // Drawn from primitives, not the SVG path: its rounded corners use
            // arc commands and the arc conversion in SVGShape distorts them.
            PlayButtonMark()
        case .rumble:
            // Also arc-based; a circle with a play triangle is the mark.
            ZStack {
                Circle().stroke(lineWidth: 2.4)
                Triangle().frame(width: 9, height: 11).offset(x: 1)
            }
        default:
            // Even-odd fill: these marks carve holes out of a solid body —
            // the Twitch eyes — which the non-zero rule fills in.
            SVGShape(d: Self.path(for: platform))
                .fill(style: FillStyle(eoFill: true))
                .aspectRatio(1, contentMode: .fit)
        }
    }

    static func path(for p: EmbedRef.Platform) -> String {
        switch p {
        case .twitch:
            return "M11.571 4.714h1.715v5.143H11.57zm4.715 0H18v5.143h-1.714zM6 0L1.714 4.286v15.428h5.143V24l4.286-4.286h3.428L22.286 12V0zm14.571 11.143l-3.428 3.428h-3.429l-3 3v-3H6.857V1.714h13.714Z"
        case .kick:
            return "M1.333 0h8v5.333H12V2.667h2.667V0h8v8H20v2.667h-2.667v2.666H20V16h2.667v8h-8v-2.667H12v-2.666H9.333V24h-8Z"
        case .youtube:
            return "M23.498 6.186a3.016 3.016 0 0 0-2.122-2.136C19.505 3.545 12 3.545 12 3.545s-7.505 0-9.377.505A3.017 3.017 0 0 0 .502 6.186C0 8.07 0 12 0 12s0 3.93.502 5.814a3.016 3.016 0 0 0 2.122 2.136c1.871.505 9.376.505 9.376.505s7.505 0 9.377-.505a3.015 3.015 0 0 0 2.122-2.136C24 15.93 24 12 24 12s0-3.93-.502-5.814zM9.545 15.568V8.432L15.818 12l-6.273 3.568z"
        case .rumble:
            return "M14.4528 13.5458c.8064-.6542.9297-1.8381.2756-2.6445a1.8802 1.8802 0 0 0-.2756-.2756 21.2127 21.2127 0 0 0-4.3121-2.776c-1.066-.51-2.256.2-2.4261 1.41a26.5101 26.5101 0 0 0 0 6.6482c.1701 1.21 1.3601 1.92 2.4261 1.41a21.2127 21.2127 0 0 0 4.3121-2.776zM12 0C5.3726 0 0 5.3726 0 12s5.3726 12 12 12 12-5.3726 12-12S18.6274 0 12 0zm0 21.6C6.6981 21.6 2.4 17.3019 2.4 12S6.6981 2.4 12 2.4s9.6 4.2981 9.6 9.6-4.2981 9.6-9.6 9.6z"
        case .vimeo:
            return "M23.9765 6.4168c-.105 2.338-1.739 5.5429-4.894 9.6088-3.2679 4.247-6.0258 6.3699-8.2898 6.3699-1.409 0-2.578-1.294-3.553-3.881l-1.9179-7.1138c-.719-2.584-1.4899-3.878-2.3159-3.878-.179 0-.806.378-1.8809 1.132L0 6.9748c1.1789-1.036 2.3409-2.0729 3.4849-3.1079C5.0577 2.4598 6.2397 1.7658 7.0266 1.6928c1.858-.179 3.002 1.0929 3.432 3.8169.465 2.939.787 4.767.967 5.482.537 2.442 1.1269 3.662 1.7709 3.662.5 0 1.251-.792 2.253-2.373 1.0009-1.582 1.5359-2.786 1.6079-3.613.144-1.374-.395-2.063-1.6079-2.063-.572 0-1.16.131-1.766.392 1.174-3.846 3.418-5.714 6.73-5.607 2.457.072 3.613 1.666 3.47 4.779z"
        }
    }
}

/// The classic play button: a rounded rectangle with a triangle cut out.
private struct PlayButtonMark: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let h = w * 0.70
            ZStack {
                RoundedRectangle(cornerRadius: w * 0.22, style: .continuous)
                    .frame(width: w, height: h)
                Triangle()
                    .frame(width: w * 0.22, height: w * 0.26)
                    .offset(x: w * 0.02)
                    .blendMode(.destinationOut)
            }
            .frame(width: w, height: g.size.height)
            .compositingGroup()
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// A SwiftUI Shape from an SVG path string in a 24x24 viewBox.
/// Supports M L H V C S Q T A Z in both absolute and relative forms.
struct SVGShape: Shape {
    let d: String
    var viewBox: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        var parser = SVGPathParser(d)
        var p = parser.parse()
        let scale = min(rect.width, rect.height) / viewBox
        let dx = rect.minX + (rect.width - viewBox * scale) / 2
        let dy = rect.minY + (rect.height - viewBox * scale) / 2
        p = p.applying(CGAffineTransform(scaleX: scale, y: scale)
                        .concatenating(CGAffineTransform(translationX: dx, y: dy)))
        return p
    }
}

private struct SVGPathParser {
    private let chars: [Character]
    private var i = 0
    private var cur = CGPoint.zero
    private var start = CGPoint.zero
    private var lastControl: CGPoint?
    private var lastCmd: Character = " "

    init(_ s: String) { chars = Array(s) }

    mutating func parse() -> Path {
        var p = Path()
        while let cmd = nextCommand() {
            apply(cmd, to: &p)
        }
        return p
    }

    // MARK: scanning

    private mutating func skipSeparators() {
        while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n" { i += 1 }
    }

    private mutating func nextCommand() -> Character? {
        skipSeparators()
        guard i < chars.count else { return nil }
        if chars[i].isLetter { let c = chars[i]; i += 1; lastCmd = c; return c }
        // A bare number repeats the previous command (implicit lineto after moveto).
        if lastCmd == "M" { lastCmd = "L"; return "L" }
        if lastCmd == "m" { lastCmd = "l"; return "l" }
        return lastCmd == " " ? nil : lastCmd
    }

    private mutating func number() -> CGFloat {
        skipSeparators()
        var s = ""
        if i < chars.count, chars[i] == "-" || chars[i] == "+" { s.append(chars[i]); i += 1 }
        while i < chars.count {
            let c = chars[i]
            if c.isNumber || c == "." { s.append(c); i += 1 }
            else if c == "e" || c == "E" {
                s.append(c); i += 1
                if i < chars.count, chars[i] == "-" || chars[i] == "+" { s.append(chars[i]); i += 1 }
            } else { break }
        }
        return CGFloat(Double(s) ?? 0)
    }

    private mutating func flag() -> Bool {
        skipSeparators()
        guard i < chars.count else { return false }
        let c = chars[i]; i += 1
        return c == "1"
    }

    private var more: Bool {
        var j = i
        while j < chars.count, chars[j] == " " || chars[j] == "," { j += 1 }
        guard j < chars.count else { return false }
        let c = chars[j]
        return c.isNumber || c == "-" || c == "+" || c == "."
    }

    // MARK: commands

    private mutating func apply(_ cmd: Character, to p: inout Path) {
        let rel = cmd.isLowercase
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
        }

        repeat {
            switch Character(cmd.uppercased()) {
            case "M":
                let q = pt(number(), number())
                p.move(to: q); cur = q; start = q; lastControl = nil
            case "L":
                let q = pt(number(), number())
                p.addLine(to: q); cur = q; lastControl = nil
            case "H":
                let x = number()
                let q = CGPoint(x: rel ? cur.x + x : x, y: cur.y)
                p.addLine(to: q); cur = q; lastControl = nil
            case "V":
                let y = number()
                let q = CGPoint(x: cur.x, y: rel ? cur.y + y : y)
                p.addLine(to: q); cur = q; lastControl = nil
            case "C":
                let c1 = pt(number(), number())
                let c2 = pt(number(), number())
                let q  = pt(number(), number())
                p.addCurve(to: q, control1: c1, control2: c2)
                cur = q; lastControl = c2
            case "S":
                let c1 = reflected()
                let c2 = pt(number(), number())
                let q  = pt(number(), number())
                p.addCurve(to: q, control1: c1, control2: c2)
                cur = q; lastControl = c2
            case "Q":
                let c = pt(number(), number())
                let q = pt(number(), number())
                p.addQuadCurve(to: q, control: c)
                cur = q; lastControl = c
            case "T":
                let c = reflected()
                let q = pt(number(), number())
                p.addQuadCurve(to: q, control: c)
                cur = q; lastControl = c
            case "A":
                let rx = number(), ry = number()
                let rot = number()
                let large = flag(), sweep = flag()
                let q = pt(number(), number())
                addArc(&p, rx: rx, ry: ry, rotation: rot,
                       largeArc: large, sweep: sweep, to: q)
                cur = q; lastControl = nil
            case "Z":
                p.closeSubpath(); cur = start; lastControl = nil
                return
            default:
                return
            }
        } while more
    }

    private func reflected() -> CGPoint {
        guard let c = lastControl else { return cur }
        return CGPoint(x: 2 * cur.x - c.x, y: 2 * cur.y - c.y)
    }

    /// SVG endpoint-parameterised arc -> centre form -> cubic segments.
    private mutating func addArc(_ p: inout Path, rx: CGFloat, ry: CGFloat,
                                 rotation: CGFloat, largeArc: Bool, sweep: Bool,
                                 to end: CGPoint) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, cur != end else {
            p.addLine(to: end); return
        }
        let phi = rotation * .pi / 180
        let dx2 = (cur.x - end.x) / 2, dy2 = (cur.y - end.y) / 2
        let x1 =  cos(phi) * dx2 + sin(phi) * dy2
        let y1 = -sin(phi) * dx2 + cos(phi) * dy2

        // Scale radii up if they can't span the endpoints.
        let lam = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lam > 1 { let s = sqrt(lam); rx *= s; ry *= s }

        let sign: CGFloat = (largeArc != sweep) ? 1 : -1
        let num = max(0, rx*rx*ry*ry - rx*rx*y1*y1 - ry*ry*x1*x1)
        let den = rx*rx*y1*y1 + ry*ry*x1*x1
        let co = sign * sqrt(den == 0 ? 0 : num / den)
        let cx1 =  co * rx * y1 / ry
        let cy1 = -co * ry * x1 / rx
        let cx = cos(phi) * cx1 - sin(phi) * cy1 + (cur.x + end.x) / 2
        let cy = sin(phi) * cx1 + cos(phi) * cy1 + (cur.y + end.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt(ux*ux + uy*uy) * sqrt(vx*vx + vy*vy)
            var a = acos(min(1, max(-1, len == 0 ? 1 : dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }

        let theta = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry,
                          (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }

        let segments = Int(ceil(abs(delta) / (.pi / 2)))
        guard segments > 0 else { p.addLine(to: end); return }
        let step = delta / CGFloat(segments)
        let k = 4.0 / 3.0 * tan(step / 4)

        var t = theta
        for _ in 0..<segments {
            let cosT = cos(t), sinT = sin(t)
            let t2 = t + step
            let cosT2 = cos(t2), sinT2 = sin(t2)

            func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: cos(phi) * rx * x - sin(phi) * ry * y + cx,
                        y: sin(phi) * rx * x + cos(phi) * ry * y + cy)
            }
            let p1 = map(cosT  - k * sinT,  sinT  + k * cosT)
            let p2 = map(cosT2 + k * sinT2, sinT2 - k * cosT2)
            let p3 = map(cosT2, sinT2)
            p.addCurve(to: p3, control1: p1, control2: p2)
            t = t2
        }
    }
}

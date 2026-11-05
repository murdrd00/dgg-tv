import Foundation
import ImageIO
import CoreGraphics
import DGGKit

// Terminal harness for DGGKit — the same code the tvOS app will import.
//   dggprobe chat [seconds]
//   dggprobe resolve <#twitch/name | #kick/name | #youtube/id>

func usage() -> Never {
    print("""
    usage:
      dggprobe chat [seconds]      connect to dgg chat, print lines + live embed list
      dggprobe resolve <ref>       resolve an embed to an HLS url
    """)
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { usage() }

switch cmd {

case "cssaudit":
    // dggprobe cssaudit <emotes.css> <emotes.json> : animations whose step size
    // doesn't match the drawn width, which reads as sliding through the art.
    guard args.count >= 3, let css = try? String(contentsOfFile: args[1], encoding: .utf8),
          let raw = FileManager.default.contents(atPath: args[2]),
          let rows = try? JSONSerialization.jsonObject(with: raw) as? [[String: Any]] else { usage() }
    let sheet = EmoteStyleSheet(css: css, base: "https://cdn/")
    var checked = 0, bad = 0
    for row in rows {
        guard let name = row["prefix"] as? String,
              let look = sheet.looks(for: EmoteContext(username: "x", emotes: [name])).first else { continue }
        for a in look.base.animations {
            guard let steps = a.steps, steps > 1,
                  let last = a.keyframes.last(where: { $0.properties["background-position"] != nil }),
                  let end = EmoteValues.px(last.properties["background-position"]) else { continue }
            let first = a.keyframes.first { $0.offset == 0 }
                .flatMap { EmoteValues.px($0.properties["background-position"]) } ?? -look.base.backgroundX
            let stride = abs(end - first) / Double(steps)
            checked += 1
            if abs(stride - look.base.width) > 0.51 {
                bad += 1
                print("\(name): width \(look.base.width) stride \(stride) steps \(steps) from \(first) to \(end)")
            }
        }
    }
    print("checked \(checked), mismatched \(bad)")
    exit(0)

case "css":
    // dggprobe css <file> <base> : prints what the engine decides for key cases
    guard args.count >= 2, let css = try? String(contentsOfFile: args[1], encoding: .utf8) else { usage() }
    let start = Date()
    let sheet = EmoteStyleSheet(css: css, base: "https://cdn/")
    print("parsed \(sheet.ruleCount) rules in \(String(format: "%.0f", Date().timeIntervalSince(start) * 1000))ms")
    func show(_ title: String, _ c: EmoteContext) {
        print("--- \(title)")
        for l in sheet.looks(for: c) {
            let anim = l.base.animations.map { "\($0.duration)s x\($0.iterations) steps \($0.steps ?? 0) hold \($0.holdsEnd) keys \($0.keyframes.count)" }
            print("  \(l.name) w \(l.base.width) h \(l.base.height) x \(l.base.backgroundX) m \(l.marginLeft)/\(l.marginRight) extras \(l.extras.count) anim \(anim)")
        }
    }
    show("catJAM alone", EmoteContext(username: "bob", emotes: ["catJAM"]))
    show("TF", EmoteContext(username: "bob", emotes: ["TF"]))
    show("WWWWaiting plain", EmoteContext(username: "bob", emotes: ["WWWWaiting"]))
    show("WWWWaiting after jaydrvernanda", EmoteContext(username: "bob", previousUsername: "JayDrVernanda", emotes: ["WWWWaiting"]))
    show("WWWWaiting from mrmouton", EmoteContext(username: "MrMouton", emotes: ["WWWWaiting"]))
    show("RaveDoge alone", EmoteContext(username: "bob", emotes: ["RaveDoge"]))
    show("RaveDoge + BERN", EmoteContext(username: "bob", emotes: ["RaveDoge", "BERN"]))
    show("ApeHands pair", EmoteContext(username: "bob", emotes: ["ApeHands", "ApeHands"]))
    show("GIGACHAD BLADE", EmoteContext(username: "bob", emotes: ["GIGACHAD", "BLADE"]))
    show("Aware", EmoteContext(username: "bob", emotes: ["Aware"]))
    show("ARRIVE combo 10", EmoteContext(username: "bob", comboCount: 10, emotes: ["ARRIVE"]))
    exit(0)

case "resolve":
    guard args.count >= 2 else { usage() }
    let refs = EmbedRef.scan(args[1])
    guard let ref = refs.first else {
        print("could not parse '\(args[1])' as an embed ref"); exit(2)
    }
    print("ref       \(ref.token)")
    print("platform  \(ref.platform.rawValue)  (on-device: \(ref.platform.resolvableOnDevice))")
    let resolver = StreamResolver()
    do {
        let url = try await resolver.resolve(ref)
        let s = url.absoluteString
        print("RESOLVED  \(s.count > 110 ? String(s.prefix(110)) + "..." : s)")
        // Prove AVPlayer would get real HLS back.
        var req = URLRequest(url: url)
        req.setValue("DGGTV/0.1", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(data: data, encoding: .utf8) ?? ""
        let isHLS = body.hasPrefix("#EXTM3U")
        print("playlist  http \(code), \(data.count) bytes, valid HLS: \(isHLS)")
        let variants = body.components(separatedBy: "\n")
            .filter { $0.contains("RESOLUTION=") }
            .compactMap { line -> String? in
                guard let r = line.range(of: "RESOLUTION=") else { return nil }
                return String(line[r.upperBound...].prefix(while: { $0 != "," }))
            }
        if !variants.isEmpty { print("variants  \(variants.joined(separator: ", "))") }
        else if isHLS { print("variants  (media playlist — single rendition)") }
    } catch {
        print("FAILED    \(error.localizedDescription)")
        exit(1)
    }

case "flairs":
    // raw decode first, with the error surfaced
    do {
        let (d, _) = try await URLSession.shared.data(from: FlairCatalog.manifest)
        print("fetched \(d.count) bytes")
        _ = try JSONDecoder().decode([Flair].self, from: d)
        print("raw decode OK")
    } catch let e as DecodingError {
        print("DECODING ERROR: \(e)")
    } catch {
        print("OTHER ERROR: \(error)")
    }
    await FlairCatalog.shared.load()
    let cat = await FlairCatalog.shared.snapshot()
    print("catalog entries: \(cat.count)")
    if cat.isEmpty { print("DECODE FAILED"); exit(1) }
    let withIcon = cat.values.filter { $0.iconURL != nil }.count
    print("with icons: \(withIcon)")
    for feats in [["flair13","subscriber"], ["moderator","protected","flair34"],
                  ["admin"], ["bot"], ["flair32","subscriber"], []] {
        let st = FlairStyle.resolve(features: feats, catalog: cat)
        print("  \(feats) -> color=\(st.colorHex ?? "nil") badges=\(st.badges.count) \(st.labels)")
    }

case "embeds":
    // Pull the live embed list off the socket, then try resolving every one.
    let c3 = ChatClient()
    let tr = EmbedTracker()
    var got = false
    let stop = Task {
        try? await Task.sleep(nanoseconds: 20_000_000_000)
        c3.disconnect()
    }
    for await ev in c3.connect() {
        if case .names(_, let users) = ev { tr.seed(users: users); got = true; c3.disconnect() }
        if case .message(let l) = ev { tr.observe(l) }
    }
    stop.cancel()
    guard got else { print("never got NAMES"); exit(1) }

    let list = tr.ranked()
    print("live embeds: \(list.count)\n")
    let resolver = StreamResolver()
    for e in list {
        let tag = "\(e.ref.token) (\(e.viewers) viewers)"
        do {
            let url = try await resolver.resolve(e.ref)
            var req = URLRequest(url: url)
            req.setValue("DGGTV/0.1", forHTTPHeaderField: "User-Agent")
            let (d, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let txt = String(data: d, encoding: .utf8) ?? ""
            let ok = txt.hasPrefix("#EXTM3U")
            let vars = txt.components(separatedBy: "\n").filter { $0.contains("RESOLUTION=") }.count
            print("  OK    \(tag)")
            print("        http \(code), HLS=\(ok), \(vars) variants, \(d.count) bytes")
        } catch {
            print("  FAIL  \(tag)")
            print("        \(error.localizedDescription)")
        }
    }

case "reconnect":
    // Connect, forcibly drop the socket, and confirm it comes back by itself.
    let rc = ChatClient()
    var msgs = 0, drops = 0, reopens = 0
    var dropped = false
    let killer = Task {
        try? await Task.sleep(nanoseconds: 50_000_000_000)
        rc.stop()
    }
    print("connecting; will force a drop after ~8s of traffic...\n")
    for await ev in rc.connect() {
        switch ev {
        case .connected:
            reopens += 1
            print("** OPEN (\(reopens))")
        case .message:
            msgs += 1
            if msgs == 40 && !dropped {
                dropped = true
                print("** forcing socket drop after \(msgs) messages")
                rc.debugForceDrop()
            }
        case .disconnected(let why):
            drops += 1
            print("** DROPPED: \(why)")
        case .reconnecting(let n, let secs):
            print("** will retry (attempt \(n)) in \(String(format: "%.1f", secs))s")
        default: break
        }
    }
    killer.cancel()
    print("\n--- result ---")
    print("messages: \(msgs)   drops: \(drops)   opens: \(reopens)")
    print(reopens >= 2 && msgs > 60
          ? "PASS: reconnected on its own and kept receiving"
          : "FAIL: did not recover")

case "frames":
    await EmoteCatalog.shared.load()
    let cat = await EmoteCatalog.shared.snapshot()
    guard let any = cat.values.compactMap(\.url).first else {
        print("no emote urls"); exit(1)
    }
    let frames = await EmoteFrames.load(anyEmoteImageURL: any)

    // Optional: name one or more emotes to inspect.
    let wanted = Set(args.dropFirst())
    if !wanted.isEmpty {
        for e in cat.values.filter({ wanted.contains($0.prefix) }) {
            let w = e.image?.first?.width ?? 0
            let h = e.image?.first?.height ?? 0
            let sp = frames[e.prefix]
            let fw = sp.flatMap { EmoteFrames.frameWidth(for: $0, sheetWidth: w) }
            print("\(e.prefix): sheet \(w)x\(h)")
            print("   frame \(fw.map(String.init) ?? "-")px  steps \(sp?.steps ?? 0)"
                  + "  start \(sp?.startPx ?? 0)  rest \(sp?.restPx.map(String.init) ?? "-")"
                  + "  animates \(sp?.animates ?? false)")
            if let sp, sp.animates {
                print(String(format: "   duration %@s -> %.1f fps",
                             sp.duration.map { String($0) } ?? "-", sp.fps))
            }
        }
        exit(0)
    }

    var animated = 0, cropped = 0, whole = 0
    var problems: [String] = []
    for e in cat.values.sorted(by: { $0.prefix < $1.prefix }) {
        let w = e.image?.first?.width ?? 0
        guard w > 0 else { continue }
        guard let sp = frames[e.prefix],
              let fw = EmoteFrames.frameWidth(for: sp, sheetWidth: w) else {
            if w > (e.image?.first?.height ?? 0) * 3 {
                problems.append("\(e.prefix): \(w)px wide, no rule -> draws whole image")
            }
            whole += 1
            continue
        }
        if sp.animates {
            animated += 1
            let runEnd = sp.startPx + sp.steps * fw
            if runEnd > w {
                problems.append("\(e.prefix): run ends \(runEnd) past sheet \(w)")
            }
        } else if fw < w {
            cropped += 1
        } else {
            whole += 1
        }
    }
    print("animated:        \(animated)")
    print("static, cropped: \(cropped)   <- hidden variants trimmed")
    print("drawn whole:     \(whole)")
    print(problems.isEmpty ? "\nno problems" : "\nPROBLEMS:")
    for p in problems.prefix(10) { print("  \(p)") }

case "gif":
    // Exercise the app's decode path on a real emote.
    guard args.count >= 2 else { print("usage: dggprobe gif <prefix>"); exit(2) }
    await EmoteCatalog.shared.load()
    let cat2 = await EmoteCatalog.shared.snapshot()
    guard let e = cat2[args[1]], let u = e.url, let url = URL(string: u) else {
        print("unknown emote \(args[1])"); exit(1)
    }
    print("url: \(u)")
    let (bytes, _) = try await URLSession.shared.data(from: url)
    print("bytes: \(bytes.count)")
    guard let src = CGImageSourceCreateWithData(bytes as CFData, nil) else {
        print("CGImageSourceCreateWithData FAILED"); exit(1)
    }
    let n = CGImageSourceGetCount(src)
    print("CGImageSourceGetCount: \(n)")
    var sizes: [String] = []
    for i in 0..<min(n, 8) {
        if let f = CGImageSourceCreateImageAtIndex(src, i, nil) {
            sizes.append("\(f.width)x\(f.height)")
        } else {
            sizes.append("nil")
        }
    }
    print("first frames: \(sizes.joined(separator: " "))")
    print(n > 1 ? "-> would animate as \(n) frames" : "-> single frame, static")

case "decodebench":
    // Time the app's decode path: how long to turn a container into frames.
    await EmoteCatalog.shared.load()
    let cat3 = await EmoteCatalog.shared.snapshot()
    let names = args.count > 1 ? Array(args.dropFirst())
                               : ["SpeedLaugh", "WHISPERING", "Listening", "ALARMA"]
    for n in names {
        guard let e = cat3[n], let u = e.url, let url = URL(string: u),
              let (bytes, _) = try? await URLSession.shared.data(from: url),
              let src = CGImageSourceCreateWithData(bytes as CFData, nil)
        else { print("\(n): unavailable"); continue }

        let count = CGImageSourceGetCount(src)
        let h: CGFloat = 52                      // 26pt @2x

        let t0 = Date()
        var kept: [CGImage] = []
        kept.reserveCapacity(count)
        for i in 0..<count {
            guard let f = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            let scale = h / CGFloat(f.height)
            let w = max(1, Int((CGFloat(f.width) * scale).rounded()))
            guard let ctx = CGContext(data: nil, width: w, height: Int(h),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { continue }
            ctx.interpolationQuality = .high
            ctx.draw(f, in: CGRect(x: 0, y: 0, width: w, height: Int(h)))
            if let o = ctx.makeImage() { kept.append(o) }
        }
        let all = Date().timeIntervalSince(t0)

        // Versus decoding ONE frame on demand.
        let t1 = Date()
        _ = CGImageSourceCreateImageAtIndex(src, count / 2, nil)
        let one = Date().timeIntervalSince(t1)

        print(String(format: "%-22@ %4d frames | all: %6.2fs | one: %6.1fms | %5.1f MB",
                     n, count, all, one * 1000,
                     Double(kept.reduce(0) { $0 + $1.width * $1.height * 4 }) / 1e6))
    }

case "verbs":
    // Dump every verb the server actually sends, so nothing stays guesswork.
    let secs = Double(args.count > 1 ? args[1] : "45") ?? 45
    let c2 = ChatClient()
    var counts: [String: Int] = [:]
    var samples: [String: String] = [:]
    let killer = Task {
        try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
        c2.disconnect()
    }
    print("listening \(Int(secs))s for all verbs...\n")
    for await ev in c2.connect() {
        if case .unhandled(let verb, let json) = ev {
            counts[verb, default: 0] += 1
            if samples[verb] == nil { samples[verb] = String(json.prefix(400)) }
        }
        if case .message = ev { counts["MSG", default: 0] += 1 }
        if case .names = ev { counts["NAMES", default: 0] += 1 }
        if case .history = ev { counts["HISTORY", default: 0] += 1 }
        if case .userUpdate = ev { counts["UPDATEUSER", default: 0] += 1 }
    }
    killer.cancel()
    print("--- verbs seen ---")
    for (v, n) in counts.sorted(by: { $0.value > $1.value }) {
        print(String(format: "  %-14@ %d", v, n))
    }
    print("\n--- first payload per non-MSG verb ---")
    for (v, j) in samples.sorted(by: { $0.key < $1.key }) {
        print("\n[\(v)]\n\(j)")
    }

case "chat":
    let seconds = Double(args.count > 1 ? args[1] : "20") ?? 20
    let client = ChatClient()
    let tracker = EmbedTracker()
    var lines = 0, embedHits = 0

    print("connecting to \(ChatClient.endpoint.absoluteString) (\(Int(seconds))s)...\n")

    let deadline = Task {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        client.disconnect()
    }

    for await event in client.connect() {
        switch event {
        case .connected:
            print("** socket open **\n")
        case .me(let nick):
            print("** connected as \(nick ?? "guest") **\n")
        case .pollStart(let p):
            print("** poll: \(p.question) \(p.options) **")
        case .pin(_, let line):
            print("** pinned: \(line?.text ?? "nothing") **")
        case .pollStop, .voteCast, .voteCounted:
            break
        case .names(let count, let users):
            tracker.seed(users: users)
            let watching = users.filter { $0.watching != nil }.count
            print("** NAMES: \(count) connections, \(users.count) users, \(watching) watching something **")
            for e in tracker.ranked().prefix(8) {
                print("     \(e.ref.token)  \(e.viewers) viewers")
            }
            print("")
        case .history(let old):
            print("** HISTORY: \(old.count) lines replayed **")
            for l in old { tracker.observe(l) }
        case .userUpdate(let u):
            tracker.update(u)
        case .message(let line):
            lines += 1
            let flair = line.primaryFlair.map { "[\($0)] " } ?? ""
            let text = line.text.count > 100 ? String(line.text.prefix(100)) + "..." : line.text
            print("\(flair)\(line.nick): \(text)")
            let found = tracker.observe(line)
            if !found.isEmpty {
                embedHits += 1
                print("   >>> EMBED \(found.map(\.token).joined(separator: " "))")
            }
        case .broadcast(let text, _):
            print("** BROADCAST: \(text)")
        case .moderated(let nick, let action):
            print("** \(action): purging messages from \(nick)")
        case .protocolError(let e):
            print("** ERR \(e)")
        case .disconnected(let why):
            print("\n** disconnected: \(why)")
        case .reconnecting(let n, let secs):
            print("** reconnecting (attempt \(n)) in \(String(format: "%.1f", secs))s")
        case .join, .quit, .unhandled:
            break
        }
    }
    deadline.cancel()

    print("\n--- summary ---")
    print("messages seen:     \(lines)")
    print("lines with embeds: \(embedHits)")
    let ranked = tracker.ranked()
    if ranked.isEmpty {
        print("embeds:            none mentioned in this window")
    } else {
        print("embed list (what left/right would cycle):")
        for (i, e) in ranked.enumerated() {
            let dev = e.ref.platform.resolvableOnDevice ? "on-device" : "not on-device"
            print(String(format: "  %d. %-34@ %-4d viewers  %@", i + 1, e.ref.token, e.viewers, dev))
        }
    }

default:
    usage()
}

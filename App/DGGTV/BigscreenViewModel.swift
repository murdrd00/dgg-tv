import Foundation
import Observation
import AVKit
import UIKit
import Security
import DGGKit

/// A chat line plus its resolved badges/colour, computed once on arrival
/// rather than on every redraw — chat runs ~400 messages a minute.
struct DisplayLine: Identifiable, Hashable {
    let line: ChatLine
    let style: FlairStyle
    /// Who sent the message above: some emotes change based on it.
    var previousNick: String?
    var id: UUID { line.id }
}

/// One row in the chat rail: either a message, or a cross-message emote combo.
/// What up and down are pointing at in chat, top to bottom.
enum RailFocus: Equatable {
    case pin
    case option(Int)
}

enum ChatItem: Identifiable {
    case message(DisplayLine)
    /// `embeds` is what its posters are watching, for darkening.
    case combo(id: UUID, emote: String, count: Int, embeds: Set<EmbedRef>)

    var id: UUID {
        switch self {
        case .message(let d): return d.id
        case .combo(let id, _, _, _): return id
        }
    }
}

/// Settings live in `UserDefaults`, read once at launch and written on change.
/// Anything missing or unreadable falls back to its default.
/// The Login Key signs in as the user, so it lives in the Keychain and is only
/// ever sent to chat. It's never logged or kept in UserDefaults.
private enum LoginKey {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.murdrd.dggtv.loginkey",
    ]

    static func load() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        var found: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &found) == errSecSuccess,
              let data = found as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String?) {
        SecItemDelete(query as CFDictionary)
        guard let key, let data = key.data(using: .utf8) else { return }
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
}

private enum Saved {
    static func value<T>(_ key: String, _ fallback: T) -> T {
        UserDefaults.standard.object(forKey: key) as? T ?? fallback
    }
    static func choice<T: RawRepresentable>(_ key: String, _ fallback: T) -> T {
        (UserDefaults.standard.object(forKey: key) as? T.RawValue).flatMap(T.init) ?? fallback
    }
    static func store(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

/// Holds a stream close to the newest video AVPlayer has.
///
/// It starts well back and has no setting that moves it: `configuredTimeOffsetFromLive`
/// made no difference to these streams. The buffer it builds up in front of itself
/// is delay and nothing else, so this skips forward through it now and then. It
/// has to be a skip: setting a rate above 1 froze live streams on a real Apple TV.
@MainActor
final class LiveEdge {
    /// Seconds of buffer to keep, from the setting.
    var base = 1.0 {
        didSet {
            cushion = base
            recent = []
        }
    }
    /// What's in use. Each stall adds a second, as this connection or stream has
    /// shown it needs more, up to a limit so it can't drift far from the setting.
    private var cushion = 1.0
    private var task: Task<Void, Never>?
    private var stalls: NSObjectProtocol?
    private var lastSkip = Date.distantPast
    /// The buffer saws up and down as segments land, so its lowest point over a
    /// segment or so is what's truly spare.
    private var recent: [Double] = []

    private func ahead(_ item: AVPlayerItem) -> Double? {
        guard let range = item.loadedTimeRanges.last?.timeRangeValue else { return nil }
        return CMTimeGetSeconds(CMTimeRangeGetEnd(range)) - CMTimeGetSeconds(item.currentTime())
    }

    private func close(_ item: AVPlayerItem, by gap: Double) async {
        let target = CMTimeAdd(item.currentTime(), CMTime(seconds: gap, preferredTimescale: 1000))
        await item.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func follow(_ item: AVPlayerItem, on player: AVPlayer) {
        stop()
        cushion = base
        lastSkip = .distantPast
        recent = []
        stalls = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cushion = min(self.cushion + 1, self.base + 3)
            }
        }
        task = Task { [weak self, weak player, weak item] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let player, let item, player.currentItem === item else { return }
                guard player.timeControlStatus == .playing, let ahead = self.ahead(item) else { continue }
                self.recent = (self.recent + [ahead]).suffix(7)
                let gap = (self.recent.min() ?? 0) - self.cushion
                guard self.recent.count == 7, gap > 0.75,
                      Date().timeIntervalSince(self.lastSkip) > 15 else { continue }
                self.lastSkip = Date()
                self.recent = []
                await self.close(item, by: gap)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if let stalls { NotificationCenter.default.removeObserver(stalls) }
        stalls = nil
    }
}

@MainActor
@Observable
final class BigscreenViewModel {

    enum Link: Equatable {
        case connecting
        case live
        case retrying(inSeconds: Int)

        var label: String {
            switch self {
            case .connecting: return "Connecting…"
            case .live: return "Live"
            case .retrying(let s): return "Reconnecting in \(s)s…"
            }
        }
    }

    var lines: [DisplayLine] = []
    /// What the rail actually draws, with combos folded in.
    var items: [ChatItem] = []
    /// Emote names, so a single-emote message can be recognised as a combo.
    var emotePrefixes: Set<String> = []
    var link: Link = .connecting
    var connected: Bool { link == .live }
    var viewerCount = 0

    // MARK: - Settings
    /// destiny.gg can split chat by what each person is watching. Every line
    /// carries `watching`, so this is just a filter.
    /// Seconds of buffer to keep on Kick, which is delay traded for fewer stalls.
    /// `liveDelayOff` plays the ordinary stream instead.
    var liveCushion: Double = Saved.value("liveCushion", 1) {
        didSet {
            Saved.store(liveCushion, "liveCushion")
            liveEdge.base = liveCushion
            let wasOff = oldValue >= Self.liveDelayOff
            guard wasOff != lowDelayOff, let selected, selected.platform == .kick else { return }
            load(selected, quality: wantsQuality)
        }
    }
    static let liveDelayOff: Double = 9
    private var lowDelayOff: Bool { liveCushion >= Self.liveDelayOff }

    /// Set by the view: true while a stream is open rather than the list.
    var isWatching = false
    /// Dims lines from people watching something else, as destiny.gg can.
    /// Saved under its old key: 2 meant this, and anything else is off.
    var darkensOtherEmbeds: Bool = Saved.value("chatFilter", 0) == 2 {
        didSet { Saved.store(darkensOtherEmbeds ? 2 : 0, "chatFilter") }
    }
    var hideOffline: Bool = Saved.value("hideOffline", true) {
        didSet {
            Saved.store(hideOffline, "hideOffline")
            tick()
        }
    }
    var chatWidth: Double = Saved.value("chatWidth", 540) {
        didSet { Saved.store(chatWidth, "chatWidth") }
    }
    var barAutoHideSeconds: Double = Saved.value("barAutoHideSeconds", 4) {
        didSet { Saved.store(barAutoHideSeconds, "barAutoHideSeconds") }
    }
    /// The top of the slider means the bar stays up for good.
    static let barNeverHides: Double = 15
    var chatFontSize: Double = Saved.value("chatFontSize", 21) {
        didSet { Saved.store(chatFontSize, "chatFontSize") }
    }

    enum ChatSide: String, CaseIterable { case right, left
        var label: String { rawValue.capitalized }
        var next: ChatSide { self == .right ? .left : .right }
    }
    /// Overlay floats over the video; pinned shrinks the video beside an
    /// opaque chat column.
    enum ChatMode: String, CaseIterable { case overlay, pinned
        var label: String { rawValue.capitalized }
        var next: ChatMode { self == .overlay ? .pinned : .overlay }
    }
    var chatSide: ChatSide = Saved.choice("chatSide", .right) {
        didSet { Saved.store(chatSide.rawValue, "chatSide") }
    }
    var chatMode: ChatMode = Saved.choice("chatMode", .overlay) {
        didSet { Saved.store(chatMode.rawValue, "chatMode") }
    }
    /// Highlighting a row on Home plays that stream muted behind the list.
    var previewOnHome: Bool = Saved.value("previewOnHome", true) {
        didSet { Saved.store(previewOnHome, "previewOnHome") }
    }
    /// Where the latency counter sits over the video, if anywhere.
    enum LatencyCorner: Int, CaseIterable {
        case off, topLeft, topRight, bottomLeft, bottomRight
        var label: String {
            switch self {
            case .off:         return "Off"
            case .topLeft:     return "Top left"
            case .topRight:    return "Top right"
            case .bottomLeft:  return "Bottom left"
            case .bottomRight: return "Bottom right"
            }
        }
        var next: LatencyCorner {
            LatencyCorner(rawValue: (rawValue + 1) % Self.allCases.count) ?? .off
        }
    }
    var latencyCorner: LatencyCorner = Saved.choice("latencyCorner", .off) {
        didSet { Saved.store(latencyCorner.rawValue, "latencyCorner") }
    }

    /// True when a line is about something other than what you're watching.
    func isOffTopic(_ item: ChatItem) -> Bool {
        guard darkensOtherEmbeds, isWatching, let sel = selected else { return false }
        switch item {
        case .message(let d):          return d.line.watching?.embed != sel
        case .combo(_, _, _, let on):  return !on.contains(sel)
        }
    }

    /// A message that is EXACTLY one emote can start or extend a combo.
    private func comboToken(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.contains(" "), emotePrefixes.contains(t) else { return nil }
        return t
    }

    var embeds: [EmbedTracker.Entry] = []
    /// What the player can switch between. YouTube is included even though it
    /// can't play here: landing on one offers to open it instead.
    var switchableEmbeds: [EmbedTracker.Entry] {
        embeds.filter { $0.ref.playsInApp || $0.ref.youTubeAppURL != nil }
    }

    /// YouTube embeds arrive as bare video ids. Token -> channel name.
    private(set) var channelNames: [String: String] = [:]
    /// Token -> stream title, for any platform that gives one.
    private(set) var titles: [String: String] = [:]
    private var nameLookups: Set<String> = []
    /// Private or removed videos.
    private var unavailableVideos: Set<String> = []
    /// Token -> is it live, and when that was last checked.
    private var videoLive: [String: (live: Bool, checked: Date)] = [:]

    func name(for ref: EmbedRef) -> String {
        channelNames[ref.token] ?? ref.displayName
    }

    private func apply(_ s: StreamStatus, to token: String) {
        if let channel = s.channel { channelNames[token] = channel }
        if let title = s.title { titles[token] = title }
        if s.unavailable { unavailableVideos.insert(token) }
        else if s.channel != nil { unavailableVideos.remove(token) }
    }

    /// New videos shouldn't wait for the 25s check to get a name.
    private func lookUpNewVideos(_ refs: [EmbedRef]) {
        for ref in refs where ref.youTubeAppURL != nil {
            guard nameLookups.insert(ref.token).inserted else { continue }
            Task { [resolver] in
                apply(await resolver.status(ref), to: ref.token)
                tick()
            }
        }
    }

    /// When a streamer restarts, the ended stream lingers with a few viewers.
    /// A channel listed twice is the signal: only then is it worth fetching
    /// the watch pages to see which one is really live. A lone finished video
    /// stays, since a mod may have put it up for everyone to watch.
    private func hiddenDuplicates(_ refs: [EmbedRef]) -> Set<String> {
        let videos = refs.filter { $0.youTubeAppURL != nil && channelNames[$0.token] != nil }
        var hidden: Set<String> = []
        for group in Dictionary(grouping: videos, by: { channelNames[$0.token] }).values
        where group.count > 1 {
            for ref in group { checkLive(ref) }
            let live = group.filter { videoLive[$0.token]?.live == true }
            guard !live.isEmpty else { continue }
            hidden.formUnion(group.filter { videoLive[$0.token]?.live == false }.map(\.token))
        }
        return hidden
    }

    private func checkLive(_ ref: EmbedRef) {
        if let known = videoLive[ref.token],
           Date().timeIntervalSince(known.checked) < 120 { return }
        // Claimed now so the 3s tick can't start a second fetch of the page.
        videoLive[ref.token] = (videoLive[ref.token]?.live ?? false, Date())
        Task {
            let state = await YouTubeInfo.pageState(videoID: ref.path)
            if state == .unknown {
                videoLive[ref.token] = nil
                return
            }
            if state == .unavailable { unavailableVideos.insert(ref.token) }
            videoLive[ref.token] = (state == .live, Date())
            tick()
        }
    }
    var selected: EmbedRef?
    /// What was playing before returning to the list, so focus lands back on
    /// that row rather than jumping to the top.
    private(set) var lastWatched: EmbedRef?
    var streamURL: URL?
    var playerError: String?
    /// A YouTube thumbnail filling in for video. Downloaded before it's shown,
    /// and kept until something replaces it, so there's never a gap.
    private(set) var backdrop: UIImage?
    private var thumbnails: [String: UIImage] = [:]

    /// TWO players for the whole app lifetime, taking turns. The next stream
    /// loads out of sight while the current one keeps playing, then they swap,
    /// so changing streams never shows a gap. Creating one inside `body` makes
    /// a new one on every redraw, and the stream never gets past buffering.
    let players: [AVPlayer] = [BigscreenViewModel.makePlayer(), BigscreenViewModel.makePlayer()]
    /// Which one is the current stream.
    private(set) var active = 0
    /// Which one is drawn on top. Both stay fully opaque, because a hidden
    /// player may not decode: the next stream comes up underneath the current
    /// one, then the current one fades out to reveal it.
    private(set) var top = 0
    private(set) var fadingOut: Int?
    /// Whether each player has a frame to show.
    @ObservationIgnored private var displayReady = [false, false]

    func setDisplayReady(_ ready: Bool, player index: Int) {
        displayReady[index] = ready
    }
    var player: AVPlayer { players[active] }
    private var standby: AVPlayer { players[1 - active] }

    private static func makePlayer() -> AVPlayer {
        let p = AVPlayer()
        // Leave this TRUE. Setting it false starts playback before enough is
        // buffered; on a slow decoder it stalls at once and never recovers
        // (the playhead freezes a few seconds in and AVKit just reheartbeats).
        p.automaticallyWaitsToMinimizeStalling = true
        return p
    }

    /// Lines arrive in bursts (~400/min). Buffer them and flush on a timer so
    /// SwiftUI redraws a few times a second instead of per message.
    private var pending: [DisplayLine] = []
    /// Lines waiting while chat is scrolled back.
    var pendingCount: Int { pending.count }

    private let client = ChatClient()
    /// Only used when the site's feed can't be reached.
    private let tracker = EmbedTracker()
    private let embedFeed = EmbedFeed()
    private var feedTask: Task<Void, Never>?
    /// The site's list. Nil until it arrives, and the app falls back to working
    /// one out from chat until then.
    private var feedItems: [EmbedFeed.Item]?

    private func receive(_ items: [EmbedFeed.Item]) {
        feedItems = items
        for item in items {
            if let name = item.name, !name.isEmpty { channelNames[item.ref.token] = name }
            if let title = item.title, !title.isEmpty { titles[item.ref.token] = title }
        }
        offline = Set(items.filter { $0.live == false }.map(\.ref.token))
        checkedOnce = true
        tick()
    }
    private let resolver = StreamResolver()
    private var flairs: [String: Flair] = [:]
    private var pump: Task<Void, Never>?
    /// True while the picture is actually moving, which is what should hold
    /// off the screensaver. A stream that ends stops counting.
    private(set) var isPlaying = false
    private var playingObservers: [NSKeyValueObservation] = []

    private func updatePlaying() {
        isPlaying = player.timeControlStatus == .playing
    }
    private let maxLines = 150

    // Signing in

    private(set) var hasLoginKey = false
    /// The name chat knows us by, once it has said.
    private(set) var accountName: String?
    private var accountChecked = false

    var accountLabel: String {
        if !hasLoginKey { return "Not signed in" }
        if let accountName { return accountName }
        return accountChecked ? "Key not accepted" : "Checking…"
    }

    // Pinned message

    private var pinned: DisplayLine?
    private var pinID = ""
    /// Hiding is per pin, as on the site: a new one always shows.
    private var hiddenPin: String = Saved.value("hiddenPin", "") {
        didSet { Saved.store(hiddenPin, "hiddenPin") }
    }

    var shownPin: DisplayLine? { pinID == hiddenPin ? nil : pinned }
    /// Something's pinned but hidden, so the small button stands in for it.
    var pinIsHidden: Bool { pinned != nil && shownPin == nil }

    private func togglePin() {
        guard pinned != nil else { return }
        hiddenPin = pinIsHidden ? "" : pinID
    }

    // What the remote points at

    /// Starts empty so that a Select pressed for something else, just as a poll
    /// appears, can't cast a vote or hide a pin.
    private(set) var railFocus: RailFocus? {
        didSet { dropPinFocusLater() }
    }
    private var railIdle: Task<Void, Never>?

    var pollFocus: Int? {
        if case .option(let i) = railFocus { return i }
        return nil
    }

    /// Set by Home while focus is over chat, where the remote works it too.
    private(set) var homeChatFocused = false
    /// True where the highlight means something.
    var railActive: Bool { isWatching || homeChatFocused }
    /// Whether there's anything in chat to go to.
    var railHasStops: Bool { !railStops.isEmpty }

    func setHomeChatFocused(_ on: Bool) {
        homeChatFocused = on
        railFocus = on ? railStops.first : nil
    }

    /// Where focus goes when what it was on has gone. Home needs a highlight
    /// for as long as focus is over chat.
    private func settleRailFocus() {
        railFocus = homeChatFocused ? railStops.first : nil
    }

    private var railStops: [RailFocus] {
        var stops: [RailFocus] = pinned == nil ? [] : [.pin]
        if pollTakesRemote, let poll {
            stops += poll.options.indices.map { .option($0) }
        }
        return stops
    }

    /// An up or down click, moving through the pin and any poll options. Up stops
    /// at the top, and down past the end lets go unless a poll or Home holds it.
    func moveRailFocus(_ by: Int) {
        if poll != nil { logPollState("move \(by)") }
        let stops = railStops
        guard !stops.isEmpty else { return }
        if let railFocus, let at = stops.firstIndex(of: railFocus) {
            let next = at + by
            if stops.indices.contains(next) {
                self.railFocus = stops[next]
            } else if by > 0, !pollTakesRemote, !homeChatFocused {
                self.railFocus = nil
            }
            return
        }
        if by < 0 || homeChatFocused {
            railFocus = stops.first
        } else if pollTakesRemote {
            railFocus = stops.first { $0 != .pin }
        }
    }

    /// Select. False means nothing was highlighted, so it does its usual job.
    func railSelect() -> Bool {
        if poll != nil { logPollState("select") }
        switch railFocus {
        case .pin:
            togglePin()
            dropPinFocusLater()
            return true
        case .option:
            return castVote()
        case nil:
            return false
        }
    }

    func clearRailFocus() { railFocus = nil }

    private func logPollState(_ what: String) {
        PollLog.add("\(what) watching=\(isWatching) homeChat=\(homeChatFocused) "
            + "focus=\(String(describing: railFocus)) takes=\(pollTakesRemote) "
            + "can=\(poll?.canVote ?? false) ended=\(poll?.ended ?? false) "
            + "myVote=\(poll?.myVote ?? 0) sent=\(String(describing: sentVote)) "
            + "left=\(Int(poll?.ends.timeIntervalSinceNow ?? 0))/\(Int(poll?.length ?? 0)) "
            + "account=\(accountName != nil)")
    }

    /// With the pin highlighted Select won't do its usual job, so don't let
    /// that linger after the remote is put down.
    private func dropPinFocusLater() {
        railIdle?.cancel()
        // On Home the highlight is where focus is, so it has to stay.
        guard railFocus == .pin, !homeChatFocused else { return }
        railIdle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, self?.railFocus == .pin else { return }
            self?.railFocus = nil
        }
    }

    // Polls

    /// What's on screen. Votes can arrive by the hundred each second, so they
    /// collect in `livePoll` and reach the screen a few times a second.
    private(set) var poll: ChatPoll?
    private var livePoll: ChatPoll?
    private var pollRefresh: Task<Void, Never>?
    private var pollHide: Task<Void, Never>?
    private var voteTimeout: Task<Void, Never>?
    /// Sent, and waiting for chat to confirm it.
    private(set) var sentVote: Int?
    private var fakePoll = false

    /// True while up, down and Select belong to the poll.
    var pollTakesRemote: Bool {
        guard let poll else { return false }
        return poll.canVote && !poll.ended && sentVote == nil
    }

    private func castVote() -> Bool {
        guard pollTakesRemote, let i = pollFocus else { return false }
        let option = i + 1
        sentVote = option
        settleRailFocus()
        if fakePoll {
            Task { await handle(.voteCounted(option: option)) }
        } else {
            client.vote(option: option)
        }
        // If it's never confirmed, let them try again.
        voteTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.sentVote = nil
        }
        return true
    }

    private func showPoll() {
        guard pollRefresh == nil else { return }
        pollRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.pollRefresh = nil
            self.poll = self.livePoll
        }
    }

    private func clearPoll() {
        pollHide?.cancel()
        pollRefresh?.cancel(); pollRefresh = nil
        voteTimeout?.cancel()
        livePoll = nil
        poll = nil
        if pollFocus != nil { settleRailFocus() }
        sentVote = nil
    }

    /// Dev hook: plays a made-up poll through the real parser. Votes in it go
    /// nowhere. `hidden` runs one whose results stay secret until the end.
    func runFakePoll(hidden: Bool = false) {
        fakePoll = true
        // The server's real format, including its date style.
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.timeZone = TimeZone(secondsFromGMT: 0)
        clock.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        let now = clock.string(from: Date())
        let start = """
        POLLSTART {"canvote":true,"myvote":0,"nick":"TEST","weighted":false,"hidden":\(hidden),\
        "start":"\(now)","now":"\(now)","time":40000,"question":"Is this poll working?",\
        "options":["Yes","No","Only on Apple TV","Ask me again later","Wait and see","Maybe","What poll?"],\
        "totals":[12,5,3,1,0,0,0],"totalvotes":21}
        """
        Task { [weak self] in
            for frame in [start] + (1...30).map({ "VOTECAST {\"vote\":\"\($0 % 3 + 1)\",\"quantity\":\($0 % 4 + 1)}" }) {
                guard let self, let event = FrameParser.parse(frame) else { return }
                await self.handle(event)
                try? await Task.sleep(for: .seconds(1))
            }
            if let self, let end = FrameParser.parse("POLLSTOP {\"totals\":[40,18,20,1,0,0,0],\"totalvotes\":79}") {
                await self.handle(end)
            }
        }
    }

    /// Nil signs out. Chat only reads who you are on connecting, so this
    /// reconnects, and starts clean because the server replays its history.
    func setLoginKey(_ key: String?) {
        let clean = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usable = clean?.isEmpty == false ? clean : nil
        LoginKey.save(usable)
        hasLoginKey = usable != nil
        accountName = nil
        accountChecked = false
        client.loginKey = usable
        stop()
        clearPoll()
        pending = []
        lines = []
        items = []
        connectChat()
    }

    private func connectChat() {
        pump = Task { [weak self] in
            guard let self else { return }
            await FlairCatalog.shared.load()
            self.flairs = await FlairCatalog.shared.snapshot()
            for await event in self.client.connect() {
                await self.handle(event)
            }
        }
    }

    func start() {
        guard pump == nil else { return }
        let key = LoginKey.load()
        client.loginKey = key
        hasLoginKey = key != nil
        // Dev hook: no sound at all, for testing where audio isn't welcome.
        if ProcessInfo.processInfo.environment["DGGTV_SILENT"] != nil {
            players.forEach { $0.volume = 0 }
        }
        // Declaring this as playback is what tvOS expects of a video app.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        playingObservers = players.map {
            $0.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.updatePlaying() }
            }
        }
        // Diagnostic hook: DGGTV_TEST_STREAM=<url> plays a known-good stream
        // instead of a resolved embed, to separate "our stream is broken"
        // from "this device can't render video at all".
        if let t = ProcessInfo.processInfo.environment["DGGTV_TEST_STREAM"],
           let u = URL(string: t) {
            testMode = true
            streamURL = u
            player.replaceCurrentItem(with: AVPlayerItem(url: u))
            player.play()
        }
        connectChat()
        feedTask = Task { [weak self, embedFeed] in
            for await items in embedFeed.updates() {
                self?.receive(items)
            }
        }
    }

    func stop() {
        pump?.cancel(); pump = nil
        client.disconnect()
    }

    private func display(_ l: ChatLine) -> DisplayLine {
        DisplayLine(line: l, style: FlairStyle.resolve(features: l.features,
                                                       catalog: flairs))
    }

    private func append(_ new: [DisplayLine]) {
        for dl in new { appendOne(dl) }
        lines.append(contentsOf: new)
        // A little at a time. Dropping lines in big batches is a large sudden
        // change to the list, which slower Apple TVs may show as chat blinking out.
        // New lines only arrive while chat is following, so this can't move
        // something being read.
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        if items.count > maxLines { items.removeFirst(items.count - maxLines) }
    }

    /// destiny.gg folds consecutive single-emote messages — from ANY users —
    /// into one counter line and drops the usernames entirely.
    private func appendOne(_ dl: DisplayLine) {
        if let token = comboToken(dl.line.text), let last = items.last {
            switch last {
            case .combo(let id, let emote, let n, let embeds) where emote == token:
                items[items.count - 1] = .combo(
                    id: id, emote: emote, count: n + 1,
                    embeds: embeds.union([dl.line.watching?.embed].compactMap { $0 }))
                return
            case .message(let prev) where comboToken(prev.line.text) == token:
                // Two in a row: replace the first message with a combo of 2.
                items[items.count - 1] = .combo(
                    id: UUID(), emote: token, count: 2,
                    embeds: Set([prev.line.watching?.embed, dl.line.watching?.embed].compactMap { $0 }))
                return
            default:
                break
            }
        }
        var line = dl
        if case .message(let above)? = items.last { line.previousNick = above.line.nick }
        items.append(.message(line))
    }

    private func handle(_ event: ChatEvent) async {
        switch event {
        case .connected:
            link = .live
        case .me(let nick):
            accountName = nick
            accountChecked = true

        case .pin(let id, let line):
            pinID = id
            pinned = line.map(display)
            if line == nil, railFocus == .pin { settleRailFocus() }

        case .pollStart(let new):
            clearPoll()
            livePoll = new
            poll = new

        case .voteCast(let option, let quantity):
            guard var p = livePoll else { break }
            if !p.hidden, p.totals.indices.contains(option - 1) {
                p.totals[option - 1] += quantity
            }
            p.votes += quantity
            livePoll = p
            showPoll()

        case .voteCounted(let option):
            voteTimeout?.cancel()
            sentVote = nil
            guard var p = livePoll else { break }
            p.canVote = false
            p.myVote = option
            livePoll = p
            poll = p

        case .pollStop(let totals, let votes):
            guard var p = livePoll else { break }
            p.ended = true
            if p.hidden, let totals, totals.count == p.options.count {
                p.hidden = false
                p.totals = totals
                p.votes = votes ?? p.votes
            }
            pollRefresh?.cancel(); pollRefresh = nil
            livePoll = p
            poll = p
            if pollFocus != nil { settleRailFocus() }
            // The same seven seconds the site leaves the result up.
            pollHide = Task { [weak self] in
                try? await Task.sleep(for: .seconds(7))
                guard !Task.isCancelled else { return }
                self?.clearPoll()
            }
        case .disconnected:
            link = .connecting
            // The site does this too, or it could sit there forever.
            clearPoll()
        case .reconnecting(_, let secs):
            link = .retrying(inSeconds: max(1, Int(secs.rounded())))

        case .names(let count, let users):
            // Check liveness as soon as we know what is out there, instead of
            // waiting for the periodic timer — the list showed dead channels
            // as live for the first several seconds.
            defer { refreshLiveness() }
            // Every connected user carries `watching`, so the embed list is
            // fully populated the instant we connect.
            viewerCount = count
            tracker.seed(users: users)
            // Force past the throttle. HISTORY arrives first and calls
            // refreshEmbeds() with an empty tracker, which starts the 2s
            // window; NAMES then lands inside it, gets throttled, and the
            // embed list stays empty with nothing ever selected.
            tick()

        case .history(let old):
            // Server replays recent lines, so chat opens full instead of blank.
            for l in old { tracker.observe(l) }
            append(old.map(display))
            refreshEmbeds()

        case .userUpdate(let u):
            tracker.update(u)

        case .message(let l):
            // Traffic means we are live, whatever the delegate reported.
            if link != .live { link = .live }
            tracker.observe(l)
            pending.append(display(l))

        case .moderated(let nick, _):
            // Match the web client: a muted/banned user's messages disappear.
            let target = nick.lowercased()
            lines.removeAll { $0.line.nick.lowercased() == target }
            pending.removeAll { $0.line.nick.lowercased() == target }
            items.removeAll {
                if case .message(let d) = $0 {
                    return d.line.nick.lowercased() == target
                }
                return false
            }

        case .broadcast, .join, .quit, .unhandled, .protocolError:
            break
        }
    }

    /// Tokens known to be offline. Only ever holds embeds we positively
    /// confirmed are down — an unreachable check leaves them visible.
    private(set) var offline: Set<String> = []
    /// Tokens confirmed LIVE. With hide-offline on we show only these, so a
    /// channel can't appear and then vanish a moment later once its check
    /// comes back — which is what made PRSEK and xQc pop in and out.
    private(set) var confirmedLive: Set<String> = []
    private(set) var checkedOnce = false
    private var livenessRun: Task<Void, Never>?

    /// Re-checked periodically; one request per Kick/Twitch embed.
    func refreshLiveness() {
        // The site's list already knows, so there's nothing to check.
        guard feedItems == nil, livenessRun == nil else { return }
        let refs = tracker.ranked().map(\.ref)
        livenessRun = Task { [resolver] in
            var down: Set<String> = []
            var up: Set<String> = []
            var found: [String: StreamStatus] = [:]
            await withTaskGroup(of: (String, StreamStatus).self) { group in
                for r in refs {
                    group.addTask { (r.token, await resolver.status(r)) }
                }
                for await (token, status) in group {
                    found[token] = status
                    if status.live == false { down.insert(token) }
                    if status.live == true { up.insert(token) }
                }
            }
            // A newer check replaced this one, and its results are the ones
            // to keep. Clearing `livenessRun` here would orphan that check.
            guard !Task.isCancelled else { return }
            for (token, status) in found { self.apply(status, to: token) }
            self.offline = down
            // Anything we couldn't check stays visible rather than vanishing.
            self.confirmedLive = up.union(refs.map(\.token)
                                            .filter { !down.contains($0) && !up.contains($0) })
            self.checkedOnce = true
            self.livenessRun = nil
            self.tick()
        }
    }

    private var lastRank = Date.distantPast
    private func refreshEmbeds() {
        // Re-ranking on every message would be wasteful at 400/min.
        guard Date().timeIntervalSince(lastRank) > 2 else { return }
        lastRank = Date()
        if let feedItems {
            // A finished YouTube video stays: a mod may have put it up on purpose.
            embeds = feedItems
                .filter { !hideOffline || $0.live != false || $0.ref.platform == .youtube }
                .map { EmbedTracker.Entry(ref: $0.ref, viewers: $0.watching) }
            return
        }
        let all = tracker.ranked()
        lookUpNewVideos(all.map(\.ref))
        let hidden = unavailableVideos.union(hiddenDuplicates(all.map(\.ref)))
        let ranked = all.filter { !hidden.contains($0.ref.token) }
        if hideOffline {
            // Before the first check nothing is known, so show everything
            // rather than an empty list; afterwards show only what is live.
            embeds = checkedOnce
                ? ranked.filter { confirmedLive.contains($0.ref.token) }
                : ranked
        } else {
            embeds = ranked
        }

        // No auto-select: the app opens on the embed list and the user picks.
    }

    func tick() { lastRank = .distantPast; refreshEmbeds() }

    /// Manual refresh from the home screen: re-rank and re-check liveness.
    func refreshNow() {
        lastRefresh = Date()
        nameLookups = Set(channelNames.keys)
        tick()
        livenessRun?.cancel()
        livenessRun = nil
        refreshLiveness()
    }

    private(set) var lastRefresh = Date.distantPast

    /// Dev hook: inject a synthetic line so animation can be tested without
    /// waiting for chat to happen to use an animated emote.
    func injectTestLine(_ text: String, nick: String = "TEST", features: [String] = []) {
        let line = ChatLine(nick: nick, features: features, text: text,
                            at: Date(), watching: nil)
        append([display(line)])
    }

    /// Called ~8x a second by the view.
    func flush() {
        guard !pending.isEmpty else { return }
        append(pending)
        pending.removeAll(keepingCapacity: true)
    }

    /// Surface stalls and failures instead of showing a silent black screen.
    private var stallObservers: [NSObjectProtocol] = []

    private func watchPlayback(_ item: AVPlayerItem) {
        stallObservers.forEach(NotificationCenter.default.removeObserver)
        stallObservers.removeAll()

        let nc = NotificationCenter.default
        stallObservers.append(nc.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.stalls += 1 }
            })
        stallObservers.append(nc.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.streamDropped(item) }
            })
    }

    /// A stream died while on screen, usually a network blip or the source
    /// restarting. The last frame stays up while it reloads, so one drop passes
    /// as a pause. A second soon after means it really has gone.
    private func streamDropped(_ item: AVPlayerItem) {
        guard item === player.currentItem, let ref = selected, ref == shown else { return }
        guard Date().timeIntervalSince(lastDropRetry) > 30 else {
            fail(Self.wontPlay)
            return
        }
        lastDropRetry = Date()
        load(ref, quality: wantsQuality)
    }
    private var lastDropRetry = Date.distantPast

    /// Select on the error screen.
    func retryStream() {
        guard playerError != nil, let ref = selected else { return }
        load(ref, quality: wantsQuality)
    }

    private static let wontPlay = "This stream wouldn't play."

    private static func explain(_ error: Error) -> String {
        if case ResolveError.offline = error { return "This stream is offline." }
        return wontPlay
    }

    var stalls = 0
    private var testMode = false

    // MARK: - Remote

    func step(_ delta: Int) {
        let list = switchableEmbeds
        guard !list.isEmpty else { return }
        let idx = list.firstIndex { $0.ref == selected } ?? 0
        // Stops at the ends: going past the busiest shouldn't land on the quietest.
        let next = idx + delta
        guard list.indices.contains(next) else { return }
        select(list[next].ref)
    }

    /// The stream on screen, which lags `selected` while the next one loads.
    private var shown: EmbedRef?
    private var wantsMuted = false
    private var wantsQuality = BigscreenViewModel.fullBitRate
    /// Bumped by every change of stream, so a slow load can see it was replaced.
    private var loadID = 0

    func stopPlayback() {
        selected = nil
        playerError = nil
        backdrop = nil
        clearPicture()
    }

    private func clearPicture() {
        loadID += 1
        players.forEach { $0.replaceCurrentItem(with: nil) }
        streamURL = nil
        shown = nil
        settleLayers()
    }

    private func settleLayers() {
        top = active
        fadingOut = nil
    }

    /// Muted and low bitrate: it sits blurred behind the list, so full quality
    /// would be wasted decoding.
    func preview(_ ref: EmbedRef) {
        guard ref != selected else { return }
        wantsMuted = true
        load(ref, quality: Self.previewBitRate)
    }

    /// Watch it properly. If it's already previewing this just turns the sound
    /// and quality up, with no reload, which is what makes entering seamless.
    func select(_ ref: EmbedRef) {
        wantsMuted = false
        guard ref == selected else {
            load(ref, quality: Self.fullBitRate)
            return
        }
        wantsQuality = Self.fullBitRate
        // Otherwise it's still loading, and these apply when it appears.
        if shown == ref {
            player.isMuted = false
            player.currentItem?.preferredPeakBitRate = peak(wantsQuality, rewritten: liveLoaders[active] != nil)
        }
    }

    /// Menu from the player.
    func leavePlayer() {
        lastWatched = selected
        guard previewOnHome else {
            stopPlayback()
            return
        }
        wantsMuted = true
        wantsQuality = Self.previewBitRate
        player.isMuted = true
        player.currentItem?.preferredPeakBitRate = peak(wantsQuality, rewritten: liveLoaders[active] != nil)
    }

    /// Keeps `selected`, so `resume` can bring the same stream back at the
    /// live edge rather than picking up minutes behind.
    func suspend() {
        clearPicture()
    }

    func resume() {
        guard let ref = selected, shown == nil else { return }
        load(ref, quality: wantsQuality)
    }

    private static let previewBitRate: Double = 1_500_000
    private static var fullBitRate: Double {
        #if targetEnvironment(simulator)
        // The simulator decodes in software and cannot keep up with 1080p60,
        // so cap it here only. Real hardware stays unlimited and AVPlayer
        // picks the best rendition on its own.
        2_500_000
        #else
        0
        #endif
    }

    /// Loads into the hidden player. What's on screen stays until this is
    /// actually running, and only a failure leaves nothing to show.
    private func load(_ ref: EmbedRef, quality: Double) {
        selected = ref
        playerError = nil
        wantsQuality = quality
        loadID += 1
        let id = loadID
        settleLayers()
        let nextIndex = 1 - active
        let next = standby
        next.replaceCurrentItem(with: nil)
        displayReady[nextIndex] = false

        guard ref.youTubeAppURL == nil else {
            player.isMuted = true
            Task {
                let image = await thumbnail(ref)
                guard id == loadID else { return }
                if let image { backdrop = image }
                // Fading in over the video, which can go once it's covered.
                try? await Task.sleep(for: .seconds(0.5))
                if id == loadID, image != nil { clearPicture() }
            }
            return
        }

        Task { [resolver] in
            do {
                let url = try await resolver.resolve(ref)
                guard id == loadID else { return }
                // Rewritten playlists are what get Kick's delay down. If one
                // ever fails, this stream goes back to the plain one.
                let lowLatency = ref.platform == .kick && !lowDelayOff
                    && !plainStreams.contains(ref.token)
                let loader = lowLatency ? LiveLoader() : nil
                liveLoaders[nextIndex] = loader
                let item = loader.map { AVPlayerItem(asset: $0.asset(for: url)) } ?? AVPlayerItem(url: url)
                item.preferredPeakBitRate = peak(quality, rewritten: lowLatency)
                item.preferredForwardBufferDuration = 4
                next.isMuted = true
                next.replaceCurrentItem(with: item)
                next.play()
                watchPlayback(item)

                let deadline = Date().addingTimeInterval(15)
                while !displayReady[nextIndex], item.status != .failed, Date() < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                    guard id == loadID else { return }
                }
                guard id == loadID else { return }
                if item.status == .failed, lowLatency {
                    plainStreams.insert(ref.token)
                    load(ref, quality: quality)
                } else if item.status == .failed {
                    fail(Self.wontPlay)
                } else if !displayReady[nextIndex], !isWatching {
                    // No picture yet: stay on the one we have. A stream being
                    // watched still goes ahead, for its audio.
                    fail("no picture")
                } else {
                    if lowLatency { liveEdge.follow(item, on: next) } else { liveEdge.stop() }
                    reveal(ref, url: url, id: id)
                }
            } catch {
                guard id == loadID else { return }
                fail(Self.explain(error))
            }
        }
    }

    /// Behind the list, what's on screen stays up, and selecting the row later
    /// tries again. While watching, the error needs showing.
    private func fail(_ message: String) {
        guard isWatching else {
            standby.replaceCurrentItem(with: nil)
            selected = shown
            return
        }
        clearPicture()
        playerError = message
    }

    private var liveLoaders: [LiveLoader?] = [nil, nil]

    /// Rewritten playlists state their bitrates scaled down, so a cap has to be too.
    private func peak(_ quality: Double, rewritten: Bool) -> Double {
        rewritten ? quality / LiveLoader.bitrateScale : quality
    }
    private var plainStreams: Set<String> = []
    @ObservationIgnored private lazy var liveEdge: LiveEdge = {
        let edge = LiveEdge()
        edge.base = liveCushion
        return edge
    }()

    private func thumbnail(_ ref: EmbedRef) async -> UIImage? {
        if let hit = thumbnails[ref.token] { return hit }
        for url in ref.youTubeThumbnailURLs {
            guard let (data, resp) = try? await URLSession.shared.data(from: url),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data) else { continue }
            thumbnails[ref.token] = image
            return image
        }
        return nil
    }

    /// Swaps the hidden player to the front.
    private func reveal(_ ref: EmbedRef, url: URL, id: Int) {
        let outgoing = player
        fadingOut = active
        active = 1 - active
        streamURL = url
        shown = ref
        backdrop = nil
        outgoing.isMuted = true
        player.isMuted = wantsMuted
        player.currentItem?.preferredPeakBitRate = peak(wantsQuality, rewritten: liveLoaders[active] != nil)
        updatePlaying()
        Task {
            try? await Task.sleep(for: .seconds(0.45))
            // A newer load already owns that player, and has cleared it.
            guard id == loadID else { return }
            outgoing.replaceCurrentItem(with: nil)
            settleLayers()
        }
    }
}

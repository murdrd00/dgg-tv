import SwiftUI
import AVKit
import DGGKit
#if DEBUG
import notify
#endif

extension Color {
    init?(hex: String?) {
        guard var h = hex?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}

#if DEBUG
/// Simulator-only stand-ins for remote buttons that can't be injected there:
/// `xcrun simctl spawn <udid> notifyutil -p gg.destiny.tv.debug.menu`
/// Each runs the same action as the real button, so focus transitions can be
/// exercised without hardware. Compiled out of Release.
enum DebugRemote {
    static let menu = Notification.Name("debug.menu")
    static let playPause = Notification.Name("debug.playpause")
    private static var tokens: [Int32] = []

    static func install() {
        guard tokens.isEmpty else { return }
        for (darwin, name) in [("gg.destiny.tv.debug.menu", menu),
                               ("gg.destiny.tv.debug.playpause", playPause)] {
            var t: Int32 = 0
            notify_register_dispatch(darwin, &t, .main) { _ in
                NotificationCenter.default.post(name: name, object: nil)
            }
            tokens.append(t)
        }
    }
}
#endif

/// Apple's blur, held part-way. A blur effect can't be given a strength, but
/// animating one in and pausing partway leaves it at that fraction. The other
/// routes failed: the full effect is far too strong, and SwiftUI's `.blur` on a
/// video layer left it black more often than not.
struct LightBlur: UIViewRepresentable {
    /// Strengths from 0 to 1, one for backdrops and one for what sits on them.
    static let backdrop: CGFloat = 0.1
    static let panel: CGFloat = 0.2

    var amount = LightBlur.backdrop
    var cornerRadius: CGFloat = 0

    final class Host: UIVisualEffectView {
        var amount: CGFloat = 0
        var radius: CGFloat = 0 { didSet { setNeedsLayout() } }
        private var animator: UIViewPropertyAnimator?
        private var observer: NSObjectProtocol?

        init() {
            super.init(effect: nil)
            layer.cornerCurve = .continuous
            clipsToBounds = true
            // The system ends paused animators in the background.
            observer = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.restart() }
            }
        }

        required init?(coder: NSCoder) { fatalError("not supported") }

        override func layoutSubviews() {
            super.layoutSubviews()
            layer.cornerRadius = min(radius, bounds.height / 2)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { restart() }
        }

        private func restart() {
            animator?.stopAnimation(true)
            effect = nil
            let a = UIViewPropertyAnimator(duration: 1, curve: .linear) { [weak self] in
                self?.effect = UIBlurEffect(style: .regular)
            }
            a.pausesOnCompletion = true
            a.fractionComplete = amount
            animator = a
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            animator?.stopAnimation(true)
        }
    }

    func makeUIView(context: Context) -> Host {
        let v = Host()
        v.amount = amount
        v.radius = cornerRadius
        return v
    }

    func updateUIView(_ v: Host, context: Context) { v.radius = cornerRadius }
}

extension View {
    /// The card behind a pin or poll. It reaches past its content on each side,
    /// so what's inside keeps the same margins as the chat around it.
    func chatCard(focused: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return padding(12)
            .background(.white.opacity(focused ? 0.2 : 0.1), in: shape)
            .overlay { if focused { shape.strokeBorder(.white, lineWidth: 3) } }
            .padding(.horizontal, -12)
            .padding(.bottom, 12)
    }

    /// The app's one panel surface. Not Liquid Glass: over moving video, two
    /// panels of that held a 2nd-generation Apple TV 4K to about 10fps, where
    /// this blur is close to free.
    ///
    /// Anything clipping this must clip the content first, then call this:
    /// a mask above a blur view can stop it blurring.
    func glassPanel(cornerRadius: CGFloat, shown: Bool = true) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background {
            ZStack {
                LightBlur(amount: LightBlur.panel, cornerRadius: cornerRadius)
                shape.fill(.black.opacity(0.3))
                shape.strokeBorder(.white.opacity(0.16), lineWidth: 1.5)
            }
            .opacity(shown ? 1 : 0)
        }
    }
}

struct BigscreenView: View {
    @State private var vm = BigscreenViewModel()
    @State private var emotes = EmoteImageStore()
    @State private var lineCache = LineCache()
    @AppStorage("chatVisible") private var chatVisible = true
    // The embed bar is a switching aid, not a permanent overlay: show it when
    // you change embeds, then get it out of the way.
    @State private var barVisible = true
    private var barNeverHides: Bool {
        vm.barAutoHideSeconds >= BigscreenViewModel.barNeverHides
    }
    @State private var hideBar: Task<Void, Never>?
    @State private var showSettings = false
    /// The blur outlasts a thumbnail's fade, or it would go sharp on its way out.
    @State private var thumbnailFading = false
    @State private var youTubeFailed = false
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var previewTask: Task<Void, Never>?
    /// The app opens on the embed list; Menu from the player returns to it.
    @State private var watching = false
    @Namespace private var barNS

    // Chat scrolling
    @State private var autoscroll = true
    /// The line at the bottom of the rail while scrolled back. A line rather
    /// than an index, because trimming old lines shifts every index.
    @State private var scrollTarget: UUID?
    @State private var scrollBase: Int?
    @State private var lastSwipeEnd = Date.distantPast
    @State private var resumeAutoscroll: Task<Void, Never>?

    private let lineDistance: CGFloat = 60
    /// How far across the remote a swipe has to go to change embeds.
    private let sidewaysToSwitch: CGFloat = 380
    @State private var sidewaysBase: CGFloat = 0
    @State private var lastSidewaysEnd = Date.distantPast
    /// -1 to 1: how close a swipe is to switching, and which way.
    @State private var barStretch: CGFloat = 0
    /// A thumb held on the remote keeps chat paused by itself, so letting go
    /// only needs long enough to lift it and start another swipe.
    private let afterSwipeHold: Duration = .seconds(2)
    private let rank  = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    private let liveness = Timer.publish(every: 25, on: .main, in: .common).autoconnect()
    private let flush = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()

    /// One continuous screen, not two. The picture and chat stay alive and in
    /// place, and only the blur and the list change, so going in and out of a
    /// stream never cuts or reloads.
    var body: some View {
        ZStack {
            stage
            chatLayer
            if watching {
                playerControls
                    .transition(.opacity)
            } else {
                HomeView(vm: vm, store: emotes,
                         onSettings: { showSettings = true },
                         onHighlight: highlight,
                         onChatPan: handlePan) { ref in
                    previewTask?.cancel()
                    vm.select(ref)
                    withAnimation(Self.screenChange) { watching = true }
                }
                .transition(.opacity.combined(with: .offset(x: vm.chatSide == .right ? -50 : 50)))
            }
        }
        // A stream holds off the screensaver; Home and an ended stream don't.
        .onChange(of: watching && vm.isPlaying, initial: true) { _, keepAwake in
            UIApplication.shared.isIdleTimerDisabled = keepAwake
        }
        .onChange(of: vm.backdrop) { old, new in
            guard old != nil, new == nil else { return }
            thumbnailFading = true
            Task {
                try? await Task.sleep(for: .seconds(0.4))
                thumbnailFading = false
            }
        }
        .onChange(of: vm.barAutoHideSeconds) { _, _ in pokeBar() }
        .onChange(of: vm.previewOnHome) { _, on in
            if !on && !watching { vm.stopPlayback() }
        }
        // Covers leaving for the YouTube app too, or the audio would carry on.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: vm.suspend()
            case .active:     vm.resume()
            default:          break
            }
        }
        .onPlayPauseCommand { showSettings = true }
        // An overlay inside this same focusable ZStack never received focus —
        // nothing highlighted and Select did nothing. A modal presentation has
        // its own focus environment, so the controls are reachable.
        .fullScreenCover(isPresented: $showSettings) {
            SettingsView(vm: vm, chatVisible: $chatVisible) {
                showSettings = false
            }
            .onExitCommand { showSettings = false }
        }
        #if DEBUG
        .onAppear { DebugRemote.install() }
        .onReceive(NotificationCenter.default.publisher(for: DebugRemote.menu)) { _ in
            if showSettings { showSettings = false }
            else if watching { leavePlayer() }
        }
        .onReceive(NotificationCenter.default.publisher(for: DebugRemote.playPause)) { _ in
            showSettings = true
        }
        #endif
        .onReceive(rank)  { _ in vm.tick() }
        .onReceive(liveness) { _ in vm.refreshLiveness() }
        .onChange(of: watching, initial: true) { _, now in vm.isWatching = now }
        .onChange(of: watching) { _, now in
            // Returning to the list re-checks it; entering a stream shows the
            // bar, which may have auto-hidden long before anything was picked.
            youTubeFailed = false
            if now { pokeBar() } else { vm.refreshNow() }
        }
        // Scrolled back, new lines wait so what you're reading holds still.
        .onReceive(flush) { _ in if autoscroll { vm.flush() } }
        .task {
            // Dev hook: the simulator can't send play/pause, so allow opening
            // Settings directly to check focus behaviour.
            if ProcessInfo.processInfo.environment["DGGTV_OPEN_SETTINGS"] != nil {
                showSettings = true
            }
            pokeBar()
            vm.start()
            vm.refreshLiveness()
            #if DEBUG
            if let kind = ProcessInfo.processInfo.environment["DGGTV_TEST_POLL"] {
                Task {
                    try? await Task.sleep(for: .seconds(8))
                    vm.runFakePoll(hidden: kind == "hidden")
                }
            }
            #endif
            await emotes.load()
            vm.emotePrefixes = emotes.allPrefixes
            // Dev hook: "nick:message|nick#flair:message", to try specific emotes.
            if let lines = ProcessInfo.processInfo.environment["DGGTV_TEST_LINES"] {
                // Repeats so they're still on screen in a fast-moving chat.
                for _ in 0..<(ProcessInfo.processInfo.environment["DGGTV_TEST_REPEAT"].flatMap(Int.init) ?? 1) {
                    for line in lines.split(separator: "|") {
                        let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                        guard parts.count == 2 else { continue }
                        let who = parts[0].split(separator: "#").map(String.init)
                        vm.injectTestLine(parts[1], nick: who[0], features: Array(who.dropFirst()))
                    }
                    try? await Task.sleep(for: .seconds(1.5))
                }
            }
        }
        .onDisappear { vm.stop() }
    }

    private static let screenChange = Animation.smooth(duration: 0.45)

    /// How far overlay chat sits from the screen edges: the tvOS safe area.
    private static let chatInset = EdgeInsets(top: 60, leading: 80, bottom: 60, trailing: 80)

    /// Chat beside the picture rather than over it.
    private var pinned: Bool { watching && vm.chatMode == .pinned && chatVisible }
    private var chatShown: Bool { !watching || chatVisible }
    /// Something to look at behind the list, so the gradient can rest.
    private var hasPicture: Bool {
        vm.streamURL != nil || vm.backdrop != nil
    }
    /// Follows what's on screen, not what's selected: a thumbnail stays up, and
    /// stays blurred, while the stream replacing it loads.
    private var pictureIsBackdrop: Bool {
        hasPicture && (!watching || vm.backdrop != nil || thumbnailFading)
    }

    /// Everything behind the controls, always in the same place.
    private var stage: some View {
        ZStack {
            HomeBackdrop(paused: hasPicture || showSettings)
            Color.black.ignoresSafeArea().opacity(watching ? 1 : 0)

            ForEach(vm.players.indices, id: \.self) { i in
                LivePlayerView(player: vm.players[i]) { ready in
                    vm.setDisplayReady(ready, player: i)
                }
                .padding(vm.chatSide == .right ? .trailing : .leading,
                         pinned ? vm.chatWidth : 0)
                .ignoresSafeArea()
                .opacity(vm.fadingOut == i ? 0 : 1)
                .zIndex(i == vm.top ? 1 : 0)
            }
            .ignoresSafeArea()
            .zIndex(1)

            // Over the video, so it can fade in before the video goes.
            if let image = vm.backdrop {
                Color.clear
                    .overlay {
                        Image(uiImage: image).resizable().scaledToFill()
                    }
                    .clipped()
                    .ignoresSafeArea()
                    .id(image)
                    .transition(.opacity)
                    .zIndex(2)
            }

            // The same treatment wherever a picture is a backdrop.
            // The blur snaps rather than fades: it's too light for that to
            // show, and fading a full-screen blur costs frames on older TVs.
            LightBlur()
                .ignoresSafeArea()
                .opacity(pictureIsBackdrop ? 1 : 0)
                .transaction { $0.animation = nil }
                .zIndex(3)
            Color.black.opacity(pictureIsBackdrop ? 0.15 : 0)
                .ignoresSafeArea()
                .zIndex(3)
        }
        .animation(.easeInOut(duration: 0.4), value: vm.fadingOut)
        .animation(Self.screenChange, value: watching)
        .animation(.easeInOut(duration: 0.35), value: vm.streamURL)
        .animation(.easeInOut(duration: 0.35), value: vm.backdrop)
    }

    /// One chat view in every mode. It changes shape rather than being swapped
    /// out, so it never rebuilds or loses its place.
    private var chatLayer: some View {
        HStack(spacing: 0) {
            if vm.chatSide == .right { Spacer(minLength: 0) }
            chatRail
                .frame(width: vm.chatWidth)
                .background(Color(white: 0.07).opacity(pinned ? 1 : 0))
                // Inline emote images would otherwise escape the rail and draw
                // over the video at the same y as their line.
                .clipShape(.rect(cornerRadius: pinned ? 0 : 28))
                .glassPanel(cornerRadius: 28, shown: !pinned)
            if vm.chatSide == .left { Spacer(minLength: 0) }
        }
        .padding(pinned ? EdgeInsets() : Self.chatInset)
        .ignoresSafeArea()
        .opacity(chatShown ? 1 : 0)
        .allowsHitTesting(false)
    }

    /// Everything that only makes sense while watching lives here, including
    /// the remote handlers. On a shared root they fired from Home too, and even
    /// with a guard the root's exit handler swallowed Menu, so the app could
    /// never be backed out of from its first screen.
    private var playerControls: some View {
        ZStack {
            if vm.streamURL == nil || vm.selected?.youTubeAppURL != nil { placeholder }

            // Embed switcher — leading-aligned, clipped rather than overflowing.
            VStack {
                HStack(spacing: 0) {
                    if vm.chatSide == .left && chatVisible {
                        Spacer().frame(width: vm.chatWidth)
                    }
                    if badgeInRow, vm.latencyCorner == .topLeft {
                        Spacer().frame(width: Self.badgeRoom)
                    }
                    embedBar
                        .clipShape(.capsule)
                        .glassPanel(cornerRadius: 999)
                        .frame(maxWidth: barRoom, alignment: .leading)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            // Stays mounted even when hidden: if the pills leave the view
            // hierarchy, focus has nowhere to return to and the remote looks
            // dead.
            .opacity(barVisible ? 1 : 0)
            .offset(y: barVisible ? 0 : -60)
            .allowsHitTesting(barVisible)
            .animation(.snappy(duration: 0.3), value: barVisible)

            if let corner = latencyAlignment, vm.selected?.youTubeAppURL == nil {
                LatencyBadge(player: vm.player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner)
                    // In the corner of the picture, not behind chat.
                    .padding(vm.chatSide == .right ? .trailing : .leading,
                             chatVisible ? vm.chatWidth + 16 : 0)
                    .allowsHitTesting(false)
            }
        }
        // Unmounted under Settings: its recognisers sit on the window, and a
        // vertical pan there would take the swipes that move between rows.
        .background {
            if !showSettings {
                RemoteTouchSurface(onPan: handlePan, onSideways: handleSideways,
                                   onSelect: selectPressed)
            }
        }
        .focusable()
        .onMoveCommand { dir in
            switch dir {
            case .left:
                clickSideways(-1)
            case .right:
                clickSideways(1)
            case .up:
                clickVertical(-1)
            case .down:
                clickVertical(1)
            @unknown default: break
            }
        }
        .onExitCommand { leavePlayer() }
        .onChange(of: vm.selected) { _, _ in youTubeFailed = false }
    }

    /// Menu from the player: the stream carries on, muted, behind the list.
    private func leavePlayer() {
        vm.clearRailFocus()
        followLiveChat()
        vm.leavePlayer()
        withAnimation(Self.screenChange) { watching = false }
    }

    /// A row got focus on Home. The wait means sweeping past rows loads none of
    /// them. Left alone for long, the preview stops so a forgotten TV isn't
    /// streaming all night.
    private func highlight(_ ref: EmbedRef) {
        previewTask?.cancel()
        guard vm.previewOnHome else { return }
        previewTask = Task {
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled else { return }
            if ref.playsInApp || ref.youTubeAppURL != nil { vm.preview(ref) }
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled, !watching else { return }
            vm.stopPlayback()
        }
    }

    /// Vertical drag scrolls chat. Horizontal is deliberately NOT handled:
    /// moving between embeds is focus movement, so tvOS provides the swipe
    /// feel (resistance, settle, commit) rather than us guessing thresholds.
    private func handlePan(_ t: CGPoint, _ phase: RemoteTouchSurface.Phase) {
        guard chatShown else { return }
        let items = vm.items
        switch phase {
        case .began:
            scrollBase = chatIndex(in: items)
            resumeAutoscroll?.cancel()
        case .changed:
            guard let base = scrollBase else { return }
            let target = base - Int(t.y / lineDistance)
            // Chat only pauses once it has really moved. A thumb resting on the
            // remote also starts a pan, and pausing for that left up scrolling
            // chat instead of reaching the pin.
            guard !autoscroll || target != base else { return }
            autoscroll = false
            scrollChat(to: target, in: items)
        case .ended:
            scrollBase = nil
            guard !autoscroll else { return }
            lastSwipeEnd = Date()
            settleChat(hold: afterSwipeHold)
        }
    }

    private func clickSideways(_ direction: Int) {
        // A swipe can arrive as a move command too once it ends.
        guard Date().timeIntervalSince(lastSidewaysEnd) > 0.4 else { return }
        pokeBar()
        vm.step(direction)
    }

    /// A swipe across the remote. It shows the bar straight away, then stretches
    /// the selected bubble towards the next one until it's far enough to switch,
    /// so a small swipe only brings the bar up. Clicks don't come through here.
    private func handleSideways(_ t: CGPoint, _ phase: RemoteTouchSurface.Phase) {
        switch phase {
        case .began:
            sidewaysBase = t.x
            pokeBar()
        case .changed:
            pokeBar()
            let travel = t.x - sidewaysBase
            guard abs(travel) >= sidewaysToSwitch else {
                barStretch = travel / sidewaysToSwitch
                return
            }
            sidewaysBase = t.x
            barStretch = 0
            vm.step(travel > 0 ? 1 : -1)
        case .ended:
            lastSidewaysEnd = Date()
            withAnimation(.snappy(duration: 0.25)) { barStretch = 0 }
        }
    }

    /// Up or down clicked. Clicks pick things, the pin and poll options, and
    /// never scroll chat: that's what swipes are for.
    private func clickVertical(_ direction: Int) {
        // A swipe can arrive as a move command too once it ends.
        guard Date().timeIntervalSince(lastSwipeEnd) > 0.4 else { return }
        if chatVisible { vm.moveRailFocus(direction) } else { pokeBar() }
    }

    private func chatIndex(in items: [ChatItem]) -> Int {
        items.firstIndex { $0.id == scrollTarget } ?? max(0, items.count - 1)
    }

    private func scrollChat(to index: Int, in items: [ChatItem]) {
        guard !items.isEmpty else { return }
        scrollTarget = items[max(0, min(items.count - 1, index))].id
    }

    /// Back at the newest line, follow live straight away. Otherwise hold the
    /// position, then return once the remote has been left alone.
    private func settleChat(hold: Duration) {
        resumeAutoscroll?.cancel()
        guard scrollTarget != vm.items.last?.id else {
            followLiveChat()
            return
        }
        resumeAutoscroll = Task {
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled else { return }
            followLiveChat()
        }
    }

    private func followLiveChat() {
        resumeAutoscroll?.cancel()
        scrollTarget = nil
        scrollBase = nil
        autoscroll = true
    }

    /// A delay badge in a top corner shares the row with the embed bar, and the
    /// bar makes room, instead of the badge dropping below it.
    private var badgeInRow: Bool {
        (vm.latencyCorner == .topLeft || vm.latencyCorner == .topRight)
            && vm.selected?.youTubeAppURL == nil
    }
    private static let badgeRoom: CGFloat = 150

    private var barRoom: CGFloat {
        1760 - (chatVisible ? vm.chatWidth + 16 : 0) - (badgeInRow ? Self.badgeRoom : 0)
    }

    private var latencyAlignment: Alignment? {
        switch vm.latencyCorner {
        case .off:         return nil
        case .topLeft:     return .topLeading
        case .topRight:    return .topTrailing
        case .bottomLeft:  return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }

    /// On a YouTube embed Select means the on-screen button. That button is
    /// only drawn, never focusable: a real one would take focus and swallow
    /// left/right, trapping you on this embed.
    private func selectPressed() {
        if chatVisible, vm.railSelect() { return }
        if let url = vm.selected?.youTubeAppURL {
            openURL(url) { opened in youTubeFailed = !opened }
        } else {
            toggleBar()
        }
    }

    private func toggleBar() {
        guard !barNeverHides else { return }
        if barVisible {
            hideBar?.cancel()
            barVisible = false
        } else {
            pokeBar()
        }
    }

    /// Reveal the embed bar, then fade it after a few idle seconds.
    private func pokeBar() {
        hideBar?.cancel()
        barVisible = true
        guard !barNeverHides else { return }
        hideBar = Task {
            try? await Task.sleep(for: .seconds(vm.barAutoHideSeconds))
            guard !Task.isCancelled else { return }
            barVisible = false
        }
    }

    private var placeholder: some View {
        VStack(spacing: 18) {
            if let ref = vm.selected, ref.youTubeAppURL != nil {
                Text(vm.name(for: ref)).font(.title2.weight(.semibold))
                    .shadow(color: .black.opacity(0.7), radius: 6)
                Text(youTubeFailed
                     ? "Couldn't open YouTube. Check that the app is installed."
                     : "YouTube streams can't play in this app.")
                    .font(.callout).foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.7), radius: 6)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    PlatformIcon(platform: .youtube).frame(width: 32, height: 32)
                    Text("Open in YouTube")
                }
                .font(.headline)
                .foregroundStyle(.black)
                .padding(.horizontal, 34).padding(.vertical, 16)
                .background(.white, in: .capsule)
                .padding(.top, 10)
            } else if let err = vm.playerError {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 56))
                Text(err).font(.title3).multilineTextAlignment(.center)
            } else {
                ProgressView()
            }
        }
        .foregroundStyle(.white)
        // Fill the space so pinned chat stays at the edge with nothing playing.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Overlay chat floats above this, so centre in what's left of the
        // screen or long messages run underneath it.
        .padding(vm.chatSide == .right ? .trailing : .leading,
                 chatVisible && vm.chatMode == .overlay ? vm.chatWidth : 0)
    }

    private var embedBar: some View {
        let all = vm.switchableEmbeds
        let idx = all.firstIndex { $0.ref == vm.selected } ?? 0
        let window = fittingPills(all, around: idx)

        return HStack(spacing: 14) {
            moreEmbeds(window.lowerBound)
            ForEach(all[window]) { embedPill($0) }
            moreEmbeds(all.count - window.upperBound)
        }
        .animation(.snappy(duration: 0.28), value: vm.selected)
        .padding(.horizontal, 24).padding(.vertical, 11)
    }

    /// As many pills as fit, spreading out from the selected one so stepping past
    /// the edge slides the list along. Names vary too much for a fixed count, and
    /// anything over would be cut off mid-pill.
    private func fittingPills(_ all: [EmbedTracker.Entry], around idx: Int) -> Range<Int> {
        guard all.indices.contains(idx) else { return 0..<min(all.count, 1) }
        // The bar's own padding, and a +X at each end.
        let room = barRoom - 48 - 2 * 76
        var lo = idx, hi = idx + 1
        var used = pillWidth(all[idx], selected: true)
        var goRight = true
        var blocked = 0
        while blocked < 2 {
            let next = goRight ? hi : lo - 1
            goRight.toggle()
            guard all.indices.contains(next) else { blocked += 1; continue }
            let width = 14 + pillWidth(all[next], selected: false)
            guard used + width <= room else { blocked += 1; continue }
            used += width
            blocked = 0
            if next >= hi { hi = next + 1 } else { lo = next }
        }
        return lo..<hi
    }

    /// Matches what `embedPill` draws, with a little to spare.
    private func pillWidth(_ entry: EmbedTracker.Entry, selected: Bool) -> CGFloat {
        func width(_ text: String, _ size: CGFloat) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: size)]).width
        }
        let name = width(vm.name(for: entry.ref), 26)
        return 32 + 26 + 7 + (selected ? name : min(name, 190)) + 7
            + width(compact(entry.viewers), 17) + 8
    }

    /// How many more are off that end of the bar. List order is by viewers, so
    /// the left means busier and the right means quieter.
    @ViewBuilder
    private func moreEmbeds(_ count: Int) -> some View {
        if count > 0 {
            Text("+\(count)")
                .font(.subheadline).monospacedDigit().foregroundStyle(.tertiary)
                .fixedSize()
        }
    }

    private func embedPill(_ entry: EmbedTracker.Entry) -> some View {
        let isOn = entry.ref == vm.selected
        return HStack(spacing: 7) {
            PlatformIcon(platform: entry.ref.platform)
                .frame(width: 26, height: 26)
            Text(vm.name(for: entry.ref))
                .lineLimit(1)
                .truncationMode(.tail)
                // The selected pill is uncapped so the full name shows
                // and the capsule grows to fit it.
                .frame(maxWidth: isOn ? nil : 190, alignment: .leading)
            Text(compact(entry.viewers))
                .font(.system(size: 17)).monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if vm.offline.contains(entry.ref.token) {
                Image(systemName: "moon.zzz")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        // Type stays constant across selection: changing size made the
        // selected name truncate MORE, and reflowed the whole row.
        .font(.system(size: 26))
        .foregroundStyle(isOn ? .white : .secondary)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background {
            if isOn {
                Capsule()
                    .fill(.white.opacity(0.20))
                    .matchedGeometryEffect(id: "embedSelection", in: barNS)
                    // Reaches towards the next bubble as a swipe goes.
                    .padding(barStretch > 0 ? .trailing : .leading, -abs(barStretch) * 70)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
    }

    private func compact(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    /// Its own view so that new chat lines redraw chat alone. As part of this
    /// view, every flush rebuilt the whole screen, Home list included.
    private var chatRail: some View {
        ChatRailView(vm: vm, emotes: emotes, lineCache: lineCache,
                     autoscroll: autoscroll, scrollTarget: scrollTarget)
    }
}

/// A poll at the top of chat. Its own view, so votes pouring in redraw this and
/// not the chat beneath it.
struct PollCard: View {
    var vm: BigscreenViewModel

    /// Polls can run long, and chat still needs the room.
    private static let shown = 4

    var body: some View {
        if let poll = vm.poll {
            VStack(alignment: .leading, spacing: 10) {
                header(poll)
                Text(poll.question)
                    .font(.system(size: vm.chatFontSize, weight: .semibold))
                    .lineLimit(3)
                ForEach(window(poll), id: \.self) { row($0, poll) }
                Text(hint(poll))
                    .font(.system(size: vm.chatFontSize * 0.75))
                    .foregroundStyle(.secondary)
                if !poll.ended { timeLeft(poll) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .chatCard()
            .transition(.opacity)
        }
    }

    /// Starts full and runs out towards the left, like a battery.
    private func timeLeft(_ poll: ChatPoll) -> some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let left = poll.ends.timeIntervalSince(context.date)
            let share = poll.length > 0 ? min(max(left / poll.length, 0), 1) : 0
            GeometryReader { box in
                Capsule()
                    .fill(Color(hex: "#0079bf") ?? .blue)
                    .frame(width: box.size.width * share)
            }
        }
        .frame(height: 5)
    }

    private func header(_ poll: ChatPoll) -> some View {
        HStack {
            Text(poll.weighted ? "Sub-weighted poll" : poll.hidden ? "Hidden poll" : "Poll")
            Spacer(minLength: 0)
            if poll.ended {
                Text("Ended")
            } else if poll.ends > .now {
                Text(timerInterval: Date.now...poll.ends, countsDown: true)
                    .monospacedDigit()
            }
        }
        .font(.system(size: vm.chatFontSize * 0.75, weight: .medium))
        .foregroundStyle(.secondary)
    }

    /// The options to draw, following the highlight down a long list.
    private func window(_ poll: ChatPoll) -> [Int] {
        let count = poll.options.count
        guard count > Self.shown else { return Array(0..<count) }
        let anchor = winner(poll) ?? highlighted ?? (poll.myVote > 0 ? poll.myVote - 1 : 0)
        let first = min(max(anchor - 1, 0), count - Self.shown)
        return Array(first..<first + Self.shown)
    }

    /// Only while the remote is working chat.
    private var highlighted: Int? { vm.railActive ? vm.pollFocus : nil }

    private func winner(_ poll: ChatPoll) -> Int? {
        guard poll.ended, !poll.hidden, let top = poll.totals.max(), top > 0 else { return nil }
        return poll.totals.firstIndex(of: top)
    }

    private func row(_ i: Int, _ poll: ChatPoll) -> some View {
        let focused = highlighted == i
        let share = poll.votes > 0 ? Double(poll.totals[i]) / Double(poll.votes) : 0
        let mine = poll.myVote == i + 1 || vm.sentVote == i + 1
        return HStack(spacing: 8) {
            if mine { Image(systemName: "checkmark") }
            Text(poll.options[i]).lineLimit(1)
            Spacer(minLength: 8)
            if !poll.hidden {
                Text("\(Int((share * 100).rounded()))%").monospacedDigit()
            }
        }
        .font(.system(size: vm.chatFontSize * 0.9, weight: winner(poll) == i ? .bold : .regular))
        .foregroundStyle(focused ? .black : .white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
            GeometryReader { box in
                ZStack(alignment: .leading) {
                    Color.white.opacity(focused ? 1 : 0.08)
                    if !poll.hidden, !focused {
                        Color.white.opacity(0.22)
                            .frame(width: box.size.width * share)
                    }
                }
            }
        }
        .clipShape(.rect(cornerRadius: 10))
        .animation(.easeOut(duration: 0.2), value: share)
    }

    private func hint(_ poll: ChatPoll) -> String {
        let more = poll.options.count > Self.shown ? " · \(poll.options.count) options" : ""
        if poll.ended { return "\(poll.votes) votes" }
        if vm.sentVote != nil { return "Sending vote…" }
        if poll.myVote > 0 { return "You voted" + more }
        if !poll.canVote { return vm.accountName == nil ? "Sign in to vote" : "\(poll.votes) votes" }
        if !vm.railActive {
            return "Click \(vm.chatSide == .right ? "right" : "left") to vote" + more
        }
        return (vm.pollFocus == nil ? "Click up or down to choose" : "Select to vote") + more
    }
}

struct ChatRailView: View {
    var vm: BigscreenViewModel
    var emotes: EmoteImageStore
    var lineCache: LineCache
    var autoscroll: Bool
    var scrollTarget: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(vm.connected ? .green : .orange)
                    .frame(width: 11, height: 11)
                Text(vm.connected ? "\(vm.viewerCount) connected" : vm.link.label)
                    .font(.caption).foregroundStyle(.secondary)
                if !autoscroll {
                    Spacer(minLength: 0)
                    Text(vm.pendingCount > 0 ? "Paused · \(vm.pendingCount) new" : "Paused")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                if vm.pinIsHidden {
                    Spacer(minLength: 0)
                    hiddenPinButton
                }
            }
            .padding(.bottom, 14)

            if let pin = vm.shownPin { pinCard(pin) }

            PollCard(vm: vm)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        ForEach(vm.items) { item in
                            Group {
                                if case .combo(_, let emote, let count, _) = item {
                                    ComboRow(emote: emote, count: count,
                                             height: vm.chatFontSize,
                                             store: emotes)
                                } else {
                                    ChatLineLabel(
                                        attributed: lineCache.string(
                                            id: item.id,
                                            generation: emotes.generation,
                                            size: vm.chatFontSize) {
                                                attributed(item)
                                            },
                                        width: vm.chatWidth - 52)
                                }
                            }
                            .opacity(vm.isOffTopic(item) ? 0.32 : 1)
                            .id(item.id)
                        }
                    }
                }
                .onChange(of: vm.items.last?.id) { _, id in
                    guard let id, autoscroll else { return }
                    // No animation: an animated scroll that restarts several
                    // times a second is what makes the text jump and settle.
                    proxy.scrollTo(id, anchor: .bottom)
                }
                .scrollIndicators(.hidden)
                // Pins the view to the bottom as content grows. scrollTo alone
                // fires before layout settles, so a just-arrived line could be
                // half-clipped until the next message nudged it.
                .defaultScrollAnchor(.bottom)
                .onChange(of: scrollTarget) { _, id in
                    // Always lands with a line on the bottom edge, the place
                    // live chat sits, but glides there rather than jumping.
                    guard let id else { return }
                    withAnimation(.smooth(duration: 0.28)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
                .onChange(of: autoscroll) { _, following in
                    if following, let id = vm.items.last?.id {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
        }
        .padding(26)
    }

    /// Builds one rail row: badges, nick in its flair colour, message with
    /// inline emotes — or a combo counter with no usernames at all.
    /// Chat's text width, less room for the pin mark.
    private var pinTextWidth: CGFloat { vm.chatWidth - 52 - vm.chatFontSize * 1.6 }

    private var pinFocused: Bool { vm.railActive && vm.railFocus == .pin }

    private func pinMark(_ focused: Bool) -> some View {
        Image(systemName: "pin.fill")
            .font(.system(size: vm.chatFontSize * 0.65))
            .foregroundStyle(focused ? .black : .secondary)
            .frame(width: vm.chatFontSize * 1.35, height: vm.chatFontSize * 1.35)
            .background(focused ? .white : .white.opacity(0.1), in: .circle)
    }

    /// Stands in for a hidden pin, so it can be brought back.
    private var hiddenPinButton: some View {
        pinMark(pinFocused)
            .frame(height: 1)
    }

    /// Drawn like any other line, so its emotes and links work, and the same
    /// width, so its text lines up with chat's. Capped, because a long pin
    /// shouldn't crowd out chat.
    private func pinCard(_ pin: DisplayLine) -> some View {
        let item = ChatItem.message(pin)
        return ChatLineLabel(
            attributed: lineCache.string(id: item.id, generation: emotes.generation,
                                         size: vm.chatFontSize) { attributed(item) },
            width: pinTextWidth)
            .frame(width: pinTextWidth)
            .frame(maxHeight: vm.chatFontSize * 6.5, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
            .clipped()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topTrailing) { pinMark(pinFocused) }
            .chatCard(focused: pinFocused)
    }

    private func attributed(_ item: ChatItem) -> NSAttributedString {
        ChatText.size = vm.chatFontSize
        let out = NSMutableAttributedString()

        switch item {
        case .combo(_, let emote, let count, _):
            out.append(ChatText.plain("\(emote) x\(count)", .white, bold: true))
            return out

        case .message(let dl):
            // As on the site: `/me` is italic with no colon, and someone
            // following themselves gets a `>` in place of their name.
            let action = dl.line.text.lowercased().hasPrefix("/me ")
            let text = action ? String(dl.line.text.dropFirst(4)) : dl.line.text
            let continued = dl.previousNick?.lowercased() == dl.line.nick.lowercased()

            if continued {
                out.append(ChatText.plain("> ", UIColor.white.withAlphaComponent(0.35)))
            } else {
                for url in dl.style.badges {
                    if let img = emotes.badge(url) {
                        out.append(ChatText.attachment(img, height: 24))
                        out.append(ChatText.plain(" ", .clear))
                    }
                }
                out.append(dl.style.rainbow
                           ? ChatText.rainbowNick(dl.line.nick)
                           : ChatText.plain(dl.line.nick,
                                            ChatText.uiColor(hex: dl.style.colorHex),
                                            bold: true))
                out.append(ChatText.plain(action ? " " : ": ",
                                          UIColor.white.withAlphaComponent(0.6)))
            }

            let words = text.split(separator: " ", omittingEmptySubsequences: true)
                .map(String.init)
            // Greentext is a perk: subscribers and staff only, as on the site.
            let green = text.hasPrefix(">")
                && !Set(dl.line.features).isDisjoint(with: ["subscriber", "moderator", "protected", "admin"])
            let textColor = green ? ChatText.greentext : UIColor.white
            // Every emote in the message at once: how each is drawn can depend
            // on the others beside it.
            var looks = emotes.looks(EmoteContext(
                username: dl.line.nick, flairs: dl.line.features,
                previousUsername: dl.previousNick,
                emotes: words.filter(emotes.isEmote)))[...]

            for (i, word) in words.enumerated() {
                if i > 0 { out.append(ChatText.plain(" ", textColor, italic: action)) }
                if emotes.isEmote(word), let look = looks.popFirst() {
                    out.append(ChatText.emote(look, store: emotes))
                } else if ChatText.isLink(word) {
                    out.append(ChatText.link(word))
                } else {
                    out.append(ChatText.plain(word, textColor, italic: action))
                }
            }
            out.addAttribute(.shadow, value: ChatText.lift,
                             range: NSRange(location: 0, length: out.length))
            return out
        }
    }


}

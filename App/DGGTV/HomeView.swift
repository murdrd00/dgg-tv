import SwiftUI
import DGGKit

/// The embed list. Chat and the background aren't part of this view: they
/// stay put in `BigscreenView` so entering a stream doesn't disturb them.
///
/// Built from a native `List` with ordinary `Button` rows, and NOT wrapped in
/// any rounded/clipping container. See `focusRoom` for how focused rows get
/// space to grow.
struct HomeView: View {
    @Bindable var vm: BigscreenViewModel
    var store: EmoteImageStore
    var onSettings: () -> Void
    var onHighlight: (EmbedRef) -> Void
    var onChatPan: (CGPoint, RemoteTouchSurface.Phase) -> Void
    var onPick: (EmbedRef) -> Void

    private enum Header {
        static let refresh = "header.refresh"
        static let settings = "header.settings"
        static let chat = "chat"
    }

    @FocusState private var focused: String?
    @State private var listClaimed = false
    @State private var refreshSpins = 0
    /// An empty list straight after connecting only means it hasn't arrived,
    /// so "nothing on" has to wait a moment or it flashes at every launch.
    @State private var emptyForReal = false

    var body: some View {
        HStack(spacing: 0) {
            if vm.chatSide == .left { chatSpace }

            VStack(alignment: .leading, spacing: 0) {
                header
                if vm.embeds.isEmpty { waiting } else { list }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .glassPanel(cornerRadius: 28)
            .padding(vm.chatSide == .right ? .trailing : .leading, 30)
            .focusSection()

            if vm.chatSide == .right { chatSpace }
        }
        // This view is rebuilt on every return from the player, and the list
        // can change underneath it, so focus must be reclaimed in both cases
        // or nothing on screen is selectable.
        .onAppear { claimFocus() }
        .onChange(of: vm.embeds.map(\.id)) { _, _ in claimFocus() }
        .onChange(of: focused, initial: true) { _, id in
            if let ref = vm.embeds.first(where: { $0.id == id })?.ref { onHighlight(ref) }
            if (id == Header.chat) != vm.homeChatFocused {
                vm.setHomeChatFocused(id == Header.chat)
            }
        }
        .onChange(of: vm.railHasStops) { _, any in
            if !any, focused == Header.chat { backToList() }
        }
        .onDisappear { vm.setHomeChatFocused(false) }
    }

    private func runRefresh() {
        refreshSpins += 1
        vm.refreshNow()
    }

    private func claimFocus() {
        let ids = vm.embeds.map(\.id)
        guard !ids.isEmpty else { return }
        let inList = focused.map(ids.contains) ?? false
        let inHeader = focused == Header.refresh || focused == Header.settings
            || focused == Header.chat
        // While the list loads the header is all there is, so tvOS puts focus
        // there. That isn't the user's choice, so the list takes it once when
        // it arrives. After that, being in the header is deliberate.
        if inList || (inHeader && listClaimed) {
            listClaimed = true
            return
        }
        listClaimed = true
        let back = vm.lastWatched?.token
        focused = ids.first { $0 == back } ?? ids.first
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text("Big Screen").font(.system(size: 46, weight: .bold))
            if !vm.embeds.isEmpty {
                Text("\(vm.embeds.count) live").font(.title3).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: vm.embeds.count)
            }
            Spacer()
            Button(action: runRefresh) {
                Label {
                    Text("Refresh")
                } icon: {
                    // The system's own effect: a rotation of ours does nothing
                    // inside a tvOS button.
                    Image(systemName: "arrow.clockwise")
                        .symbolEffect(.rotate.clockwise, options: .nonRepeating, value: refreshSpins)
                }
            }
            .focused($focused, equals: Header.refresh)
            Button(action: onSettings) {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
            }
            .focused($focused, equals: Header.settings)
        }
        .padding(.horizontal, 44)
        .padding(.top, 30)
        .padding(.bottom, 6)
    }

    private var waiting: some View {
        VStack(spacing: 20) {
            if emptyForReal {
                Image(systemName: "tv").font(.system(size: 56)).foregroundStyle(.secondary)
                Text("Nothing on the Big Screen right now").font(.title3)
                Text("Embeds appear here when people start watching.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ProgressView()
                if !vm.connected {
                    Text(vm.link.label).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: vm.connected) {
            emptyForReal = false
            guard vm.connected else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation { emptyForReal = true }
        }
    }

    private var list: some View {
        List {
            ForEach(vm.embeds) { entry in
                Button {
                    onPick(entry.ref)
                } label: {
                    // Equatable so rows that haven't changed are left alone
                    // when the list above them updates mid-scroll.
                    EmbedRow(platform: entry.ref.platform,
                             name: vm.name(for: entry.ref),
                             title: vm.titles[entry.ref.token],
                             viewers: entry.viewers,
                             offline: vm.offline.contains(entry.ref.token))
                        .equatable()
                }
                .focused($focused, equals: entry.ref.token)
            }
        }
        .listStyle(.plain)
        // Lines the row text up with the title, inside the panel.
        .focusRoom(14)
    }

    /// Chat itself lives in `BigscreenView`, under this. This is the stop on
    /// Home that hands up, down and Select to its pins and polls, there only
    /// when there's something to reach.
    private var chatSpace: some View {
        Color.clear
            .frame(width: vm.chatWidth)
            .background {
                if focused == Header.chat {
                    // Scrolling goes with the pin, the way it's reached in the
                    // player. On a poll option, a swipe does nothing.
                    RemoteTouchSurface(onPan: { t, phase in
                        if vm.railFocus == .pin || phase == .ended { onChatPan(t, phase) }
                    }, onSelect: { _ = vm.railSelect() })
                }
            }
            .focusable(vm.railHasStops)
            .focused($focused, equals: Header.chat)
            .onMoveCommand { dir in
                switch dir {
                case .up:    vm.moveRailFocus(-1)
                case .down:  vm.moveRailFocus(1)
                case .left:  if vm.chatSide == .right { backToList() }
                case .right: if vm.chatSide == .left { backToList() }
                @unknown default: break
                }
            }
            .onExitCommand { backToList() }
    }

    private func backToList() {
        let ids = vm.embeds.map(\.id)
        focused = ids.first { $0 == vm.lastWatched?.token } ?? ids.first ?? Header.refresh
    }
}

private struct EmbedRow: View, Equatable {
    let platform: EmbedRef.Platform
    let name: String
    let title: String?
    let viewers: Int
    let offline: Bool

    var body: some View {
        HStack(spacing: 18) {
            RowPlatformIcon(platform: platform)
                .frame(width: 34, height: 34)
            Text(name)
                .fontWeight(.semibold)
                .lineLimit(1)
                .layoutPriority(1)
            if let title {
                Text(title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 16)
            if offline {
                RowStatusIcon(symbol: "moon.zzz", tint: .secondary)
            }
            Text(viewers.formatted())
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

/// Marks inside a focusable row. Rows turn white when focused, and unlike
/// `Text` these don't invert with it, so they would vanish into the highlight.
private struct RowPlatformIcon: View {
    let platform: EmbedRef.Platform
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        PlatformIcon(platform: platform)
            .foregroundStyle(isFocused ? Color.black : Color.white)
    }
}

private struct RowStatusIcon: View {
    let symbol: String
    let tint: Color
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(isFocused ? Color.black : tint)
    }
}

/// What Home's glass refracts. Liquid Glass only exists as a response to what
/// is behind it: over flat black it has nothing to bend and reads as a grey
/// box, which is what happened when Home got a black background. Over video
/// the stream does this job.
///
/// A slowly drifting mesh gradient: the colours stay put and the points between
/// them wander. Movement per frame is tiny, so a low frame rate is invisible.
struct HomeBackdrop: View {
    var paused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20,
                                paused: paused || reduceMotion)) { timeline in
            gradient(at: timeline.date.timeIntervalSinceReferenceDate)
        }
        .ignoresSafeArea()
    }

    /// `amount` either way around `base`, once every `period` seconds.
    private func drift(_ base: Float, _ amount: Float, _ period: Double,
                       _ t: Double) -> Float {
        base + amount * Float(sin(t / period * 2 * .pi))
    }

    private func gradient(at t: Double) -> some View {
        MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [drift(0.5, 0.16, 47, t), 0], [1, 0],
                [0, drift(0.5, 0.16, 53, t)],
                [drift(0.62, 0.14, 37, t), drift(0.42, 0.14, 43, t)],
                [1, drift(0.5, 0.18, 41, t)],
                [0, 1], [drift(0.5, 0.18, 59, t), 1], [1, 1],
            ],
            colors: [
                Color(red: 0.03, green: 0.04, blue: 0.09),
                Color(red: 0.05, green: 0.08, blue: 0.20),
                Color(red: 0.13, green: 0.20, blue: 0.48),
                Color(red: 0.02, green: 0.03, blue: 0.07),
                Color(red: 0.06, green: 0.08, blue: 0.20),
                Color(red: 0.28, green: 0.16, blue: 0.52),
                Color(red: 0.02, green: 0.02, blue: 0.05),
                Color(red: 0.04, green: 0.05, blue: 0.13),
                Color(red: 0.08, green: 0.26, blue: 0.46),
            ]
        )
    }
}

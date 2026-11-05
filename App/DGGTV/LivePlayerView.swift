import SwiftUI
import AVKit

/// A bare video surface: no scrubber, no transport controls, no Now Playing UI.
///
/// `VideoPlayer` always brings AVKit's playback controls, which are meaningless
/// for a live stream — there is nothing to seek to. This wraps an
/// `AVPlayerLayer` directly so the picture is all you get.
struct LivePlayerView: UIViewRepresentable {

    let player: AVPlayer
    /// Whether a frame is actually ready to show. "Playing" can come first,
    /// and swapping to a player at that point shows nothing.
    var onDisplayReady: (Bool) -> Void = { _ in }

    final class Surface: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var onDisplayReady: (Bool) -> Void = { _ in }
        private var readyObserver: NSKeyValueObservation?

        func watchReadiness() {
            readyObserver = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] l, _ in
                let ready = l.isReadyForDisplay
                DispatchQueue.main.async { self?.onDisplayReady(ready) }
            }
        }
    }

    func makeUIView(context: Context) -> Surface {
        let v = Surface()
        // Clear, so the background shows until the first frame arrives.
        v.backgroundColor = .clear
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        v.onDisplayReady = onDisplayReady
        v.watchReadiness()
        return v
    }

    func updateUIView(_ v: Surface, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        v.onDisplayReady = onDisplayReady
    }
}

/// How far behind live the picture is, like an FPS counter.
///
/// `currentDate()` is the wall-clock time of the frame on screen, taken from
/// the stream's `EXT-X-PROGRAM-DATE-TIME` tags, so this is real delay rather
/// than distance from the end of the playlist. Shows a dash while buffering,
/// when the playhead isn't moving and the figure means nothing, and for a
/// stream without those tags.
struct LatencyBadge: View {
    let player: AVPlayer

    // Held in state so chat redraws of the parent don't restart the timer.
    @State private var tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var label = "–"

    var body: some View {
        Text(label)
            .font(.system(size: 22, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .glassPanel(cornerRadius: 999)
            .onReceive(tick) { now in
                guard player.timeControlStatus == .playing,
                      let frame = player.currentItem?.currentDate() else {
                    label = "–"
                    return
                }
                label = String(format: "%.1fs", max(0, now.timeIntervalSince(frame)))
            }
    }
}

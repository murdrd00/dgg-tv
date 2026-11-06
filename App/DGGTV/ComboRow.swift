import SwiftUI
import DGGKit

/// A combo line: the emote, then the running count.
///
/// Drawn as a real view rather than attributed text so the emote can pop each
/// time the count ticks up, and so an animated emote actually plays.
struct ComboRow: View {
    let emote: String
    let count: Int
    let height: CGFloat
    var store: EmoteImageStore

    @State private var scale: CGFloat = 1
    @State private var shrink: Task<Void, Never>?

    private static let popScale: CGFloat = 1.22
    /// Just over a normal emote. The pop is what makes a combo stand out.
    private var base: CGFloat { ChatText.emoteHeight * 1.2 }
    /// Keeps the very widest emotes inside the rail with room for the count.
    private static let widest: CGFloat = 340
    /// The row always reserves the POPPED height. scaleEffect doesn't change
    /// layout, but without the reserve the grown emote would be clipped by the
    /// row's bounds, and reserving it means chat never reflows either.
    private var reserved: CGFloat { base * Self.popScale }

    private var look: EmoteLook? {
        store.looks(EmoteContext(username: "", comboCount: count, emotes: [emote])).first
    }

    var body: some View {
        HStack(spacing: 10) {
            emoteView
            Text("x\(count)")
                .font(.system(size: height * 1.1, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .frame(height: reserved)
        .onChange(of: count) { _, _ in pop() }
    }

    /// Sized to the emote rather than a fixed square, and popping from its left
    /// edge: a wide one in a square spilled out both sides and was cut off.
    @ViewBuilder
    private var emoteView: some View {
        if let look {
            let size = min(base / 30, Self.widest / CGFloat(look.advance))
            let width = CGFloat(look.advance) * size
            EmoteView(look: look, scale: size, store: store)
                .frame(width: width, height: base)
                .scaleEffect(scale, anchor: .leading)
                .frame(width: width * Self.popScale, alignment: .leading)
        } else {
            Text(emote).font(.system(size: height * 0.8, weight: .bold))
        }
    }

    /// Fast out, slightly slower back — and restartable mid-flight, because
    /// counts climb faster than the animation finishes.
    private func pop() {
        shrink?.cancel()
        withAnimation(.easeOut(duration: 0.045)) { scale = Self.popScale }
        shrink = Task {
            try? await Task.sleep(for: .seconds(0.045))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.11)) { scale = 1.0 }
        }
    }
}

import SwiftUI
import UIKit

extension View {
    /// Room for a focused `List` row to grow into.
    ///
    /// tvOS enlarges a focused row, and a `List` clips to its own bounds, so
    /// rows that span the full width get their sides sliced off. The margin
    /// has to be INSIDE the list: padding around it moves the clip edge along
    /// with it and changes nothing. `contentMargins` looks right but only
    /// shifts rows on tvOS without narrowing them, pushing them off the far
    /// side instead. Vertical room is for the first and last rows, which grow
    /// into the top and bottom edges the same way.
    func focusRoom(_ margin: CGFloat = 44) -> some View {
        safeAreaPadding(.horizontal, margin)
            .safeAreaPadding(.vertical, 16)
    }
}

/// Every settings row is a `Button` with this one layout, so they share a
/// height and the same native focus treatment. A `Toggle` row is taller than a
/// `Button` row, and a merely `.focusable()` row gets no highlight at all.

/// Label on the left, current value on the right. Select runs `action`.
struct ValueRow: View {
    let label: String
    let value: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(label)
                Spacer(minLength: 20)
                Text(value).foregroundStyle(.secondary)
            }
        }
    }
}

/// On/off, in the same style as the rest.
struct SwitchRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        ValueRow(label: label, value: isOn ? "On" : "Off") { isOn.toggle() }
    }
}

/// Numeric row. Left/right clicks step it and a horizontal swipe moves it in
/// whole steps. Select does nothing: the row is only a `Button` for its focus
/// treatment.
struct SliderRow: View {
    /// How far a swipe travels per step, in the remote's touch points. Every
    /// row uses the same distance so a step feels alike whatever it changes.
    private static let swipePerStep: CGFloat = 210

    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var format: (Double) -> String = { "\(Int($0))" }

    @FocusState private var focused: Bool
    @State private var panBase: Double?
    /// Where the finger is between steps, so the bar moves with it and settles
    /// on the step afterwards. The number only ever shows real steps.
    @State private var fingerValue: Double?

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        return span > 0 ? min(1, max(0, ((fingerValue ?? value) - range.lowerBound) / span)) : 0
    }

    var body: some View {
        Button {} label: {
            HStack(spacing: 22) {
                Text(label)
                Spacer(minLength: 16)
                SliderTrack(fraction: fraction, following: fingerValue != nil)
                Text(format(value))
                    .monospacedDigit()
                    .frame(minWidth: 90, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }
        }
        .focused($focused)
        .overlay {
            if focused {
                RemoteTouchSurface(onPan: handlePan,
                                   onStep: { value = snapped(value + step * Double($0)) },
                                   verticalOnly: false)
            }
        }
    }

    private func handlePan(_ t: CGPoint, _ phase: RemoteTouchSurface.Phase) {
        switch phase {
        case .began:
            panBase = value
        case .changed:
            guard let base = panBase else { return }
            let steps = t.x / Self.swipePerStep
            fingerValue = min(range.upperBound, max(range.lowerBound, base + steps * step))
            value = snapped(base + steps.rounded(.towardZero) * step)
        case .ended:
            panBase = nil
            fingerValue = nil
        }
    }

    /// Nearest step inside the range.
    private func snapped(_ v: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, (v / step).rounded() * step))
    }
}

/// The value as a small bar. A separate view so it can read focus: the row
/// turns white when focused and the bar has to flip with it.
private struct SliderTrack: View {
    let fraction: Double
    var following = false
    @Environment(\.isFocused) private var isFocused

    private let width: CGFloat = 220

    var body: some View {
        Capsule()
            .fill(isFocused ? Color.black.opacity(0.18) : Color.white.opacity(0.18))
            .frame(width: width, height: 8)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(isFocused ? Color.black : Color.white.opacity(0.7))
                    .frame(width: max(8, width * fraction), height: 8)
                    // Straight to the finger, and eased only when settling.
                    .animation(following ? nil : .snappy(duration: 0.18), value: fraction)
            }
    }
}

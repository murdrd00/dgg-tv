import SwiftUI
import UIKit

/// Continuous Siri Remote trackpad input, plus left/right and Select clicks.
///
/// `onMoveCommand` only reports discrete steps AFTER a swipe completes, which
/// is why switching felt like a jump-cut with the animation trailing it. The
/// Siri Remote delivers indirect touches, so a pan recogniser gives live
/// translation and lets the UI track the finger the way tvOS normally does.
///
/// The recognisers go on the WINDOW for as long as this view is mounted, so
/// mount it only while the control it serves is focused. Remote input is
/// routed by focus rather than by position on screen, and a `Button` keeps
/// presses to itself: `onMoveCommand` never fires on one, and a recogniser on a
/// sibling overlay isn't in the path. The window always is.
struct RemoteTouchSurface: UIViewRepresentable {

    enum Phase { case began, changed, ended }

    var onPan: (CGPoint, Phase) -> Void
    /// A click on the left (-1) or right (+1) of the remote.
    var onStep: ((Int) -> Void)?
    /// A click on the centre of the remote.
    var onSelect: (() -> Void)?
    /// Sliders need horizontal pans; the main view must not take them.
    var verticalOnly = true

    func makeUIView(context: Context) -> Host {
        let v = Host()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false

        let c = context.coordinator
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.handle(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        // Only claim one axis. A pan recogniser that accepts both swallows
        // swipes before the focus engine can turn them into move commands.
        pan.delegate = c

        // Presses are only claimed by a caller that wants them, so the player
        // keeps getting left/right as move commands.
        var recognizers: [UIGestureRecognizer] = [pan]
        if onStep != nil {
            recognizers.append(tap(.leftArrow, c, #selector(Coordinator.stepLeft)))
            recognizers.append(tap(.rightArrow, c, #selector(Coordinator.stepRight)))
        }
        if onSelect != nil {
            recognizers.append(tap(.select, c, #selector(Coordinator.select)))
        }
        v.recognizers = recognizers
        return v
    }

    private func tap(_ press: UIPress.PressType, _ target: Coordinator,
                     _ action: Selector) -> UITapGestureRecognizer {
        let r = UITapGestureRecognizer(target: target, action: action)
        r.allowedPressTypes = [NSNumber(value: press.rawValue)]
        return r
    }

    func updateUIView(_ v: Host, context: Context) {
        context.coordinator.onPan = onPan
        context.coordinator.onStep = onStep
        context.coordinator.onSelect = onSelect
        context.coordinator.verticalOnly = verticalOnly
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPan: onPan) }

    final class Host: UIView {
        var recognizers: [UIGestureRecognizer] = []

        override func didMoveToWindow() {
            super.didMoveToWindow()
            for r in recognizers {
                r.view?.removeGestureRecognizer(r)
                window?.addGestureRecognizer(r)
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onPan: (CGPoint, Phase) -> Void
        var onStep: ((Int) -> Void)?
        var onSelect: (() -> Void)?
        var verticalOnly = true
        init(onPan: @escaping (CGPoint, Phase) -> Void) { self.onPan = onPan }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return true }
            let v = pan.velocity(in: pan.view)
            // Claim only the axis we want. Taking both axes swallows the
            // swipes the focus engine needs; taking neither means a swipe
            // arrives as a single discrete step instead of a slide.
            return verticalOnly ? abs(v.y) > abs(v.x) : abs(v.x) > abs(v.y)
        }

        @objc func handle(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            switch g.state {
            case .began:   onPan(t, .began)
            case .changed: onPan(t, .changed)
            case .ended, .cancelled, .failed: onPan(t, .ended)
            default: break
            }
        }

        @objc func stepLeft()  { onStep?(-1) }
        @objc func stepRight() { onStep?(1) }
        @objc func select()    { onSelect?() }
    }
}

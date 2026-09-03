import RemoteCore
import SwiftUI

/// The Apple TV-style D-pad: swipe to move focus one step, tap to select.
/// Chosen in Settings (`DpadStyle.trackpad`); `DPadView` is the other half of
/// that switch and remains the default.
///
/// Every step is a discrete arrow press, so this moves FOCUS and works in
/// every TV app. It is deliberately NOT the free cursor — inside the TV
/// browser, Pointer mode is the right surface, because a discrete press
/// barely moves the browser's cursor at all (`SwipePadEngine` carries that
/// history).
///
/// Unlike `DPadView` this view holds no key: a step is press-and-release in
/// one message. So there is nothing to release on `onDisappear`, and none of
/// the second-finger/sheet/teardown guards that surround the held-key pad
/// apply here. That is the main reason to keep the two views separate rather
/// than parameterising one.
struct SwipePadView: View {
    let press: (KeyCommand) -> Void
    /// Settings' "Acceleration". Read once per view identity; `RemoteView`
    /// re-reads it on the way back from Settings and passes a fresh value,
    /// which re-creates the engine below.
    let acceleration: Bool

    @State private var pad: SwipePadEngine
    /// `DragGesture` gives no "began" callback, so the first `onChanged` of
    /// each touch has to be recognised and used to seed the engine's origin.
    @State private var touching = false

    init(press: @escaping (KeyCommand) -> Void, acceleration: Bool) {
        self.press = press
        self.acceleration = acceleration
        _pad = State(initialValue: SwipePadEngine(multiStep: acceleration))
    }

    var body: some View {
        surface.gesture(swipeGesture)
    }

    private var surface: some View {
        RoundedRectangle(cornerRadius: 26)
            .fill(Theme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 26)
                    .stroke(Color.white.opacity(0.05), lineWidth: 1)
            )
            .overlay(caption)
            .frame(height: 244)
            .contentShape(RoundedRectangle(cornerRadius: 26))
            .accessibilityElement()
            .accessibilityLabel("Trackpad — swipe to move, tap to select")
            // A swipe is unreachable for VoiceOver, so every step this pad can
            // produce is also offered as a named action.
            .accessibilityAction(named: "Up") { press(.up) }
            .accessibilityAction(named: "Down") { press(.down) }
            .accessibilityAction(named: "Left") { press(.left) }
            .accessibilityAction(named: "Right") { press(.right) }
            .accessibilityAction { press(.ok) }
    }

    private var caption: some View {
        VStack(spacing: 10) {
            Image(systemName: "hand.draw")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Theme.accent)
            Text("Swipe to move")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text("Tap to select")
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent.opacity(0.8))
        }
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard touching else {
                    // Touch-down. `minimumDistance: 0` means this fires with
                    // the finger still at its origin, so there is no movement
                    // to account for yet.
                    touching = true
                    pad.began(at: value.location)
                    return
                }
                emit(pad.moved(to: value.location))
            }
            .onEnded { value in
                guard touching else { return }
                touching = false
                // The last movement still counts: a swipe that crosses its
                // final threshold between the last onChanged and lift-off
                // would otherwise be silently dropped.
                emit(pad.moved(to: value.location))
                guard pad.ended() else { return }
                press(.ok)
                Haptics.tap()
            }
    }

    private func emit(_ steps: [SwipePadEngine.Step]) {
        for step in steps {
            press(key(for: step))
            // One buzz per step, so a multi-step drag feels like the detents
            // it is rather than one undifferentiated slide.
            Haptics.tap()
        }
    }

    private func key(for step: SwipePadEngine.Step) -> KeyCommand {
        switch step {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        }
    }
}

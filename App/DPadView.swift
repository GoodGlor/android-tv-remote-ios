import RemoteCore
import SwiftUI

/// The D-pad. Its four arrows HOLD their key for as long as the finger is
/// down: the TV browser's cursor barely twitches on a discrete press and
/// only glides while Android auto-repeats a held key (real-TV finding,
/// docs/phase2-notes.md). A quick tap is simply a very short hold, which is
/// what a physical remote's arrow does too.
///
/// OK and everything else stay on `press` — they are discrete keys, and
/// `.menu` in particular already means "OK, held" over in `KeyCodeMap`.
///
/// The safety rule: a held key must ALWAYS come back up. `hold(nil)` fires
/// from `onEnded` (finger up, and also how SwiftUI finishes a cancelled
/// drag) and again from `onDisappear` for the paths that deliver no
/// `onEnded` at all — switching modes mid-press, the remote screen being
/// torn down. `RemoteView`'s keyboard-sheet and settings `onChange` guards
/// cover the second-finger case (a sheet or the settings gear reachable
/// while an arrow is held). `PointerView` holds no key of its own — Pointer
/// mode drives the real cursor directly, not a held direction — so this is
/// the only view with a hold to release. Backgrounding is covered further
/// up, where `RootView` disconnects, which releases too.
struct DPadView: View {
    let press: (KeyCommand) -> Void
    /// `TVController.setHeldDirection` — nil releases whatever is held.
    let hold: (KeyCommand?) -> Void

    /// Which arrow the finger is on, or nil. Drives the pressed styling and
    /// answers "have we already started this hold?" so the buzz fires once
    /// instead of on every gesture update. Only one arrow can be here at a
    /// time: a `DragGesture` belongs to the view it started in and keeps
    /// receiving updates even as the finger wanders off it.
    @State private var pressedDirection: KeyCommand?

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.surface)
                .overlay(Circle().stroke(Color.white.opacity(0.05), lineWidth: 1))
            directionButton("chevron.up", .up, "Up").offset(y: -88)
            directionButton("chevron.down", .down, "Down").offset(y: 88)
            directionButton("chevron.left", .left, "Left").offset(x: -88)
            directionButton("chevron.right", .right, "Right").offset(x: 88)
            Button {
                press(.ok)
            } label: {
                Text("OK")
                    .font(.system(size: 17, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.background)
                    .frame(width: 92, height: 92)
                    .background(Theme.accent, in: Circle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("OK")
        }
        .frame(width: 244, height: 244)
        .onDisappear {
            // No onEnded arrives when the view goes away mid-press. Without
            // this the TV keeps scrolling with nothing left on screen to stop
            // it. Unconditional, like every other release path.
            pressedDirection = nil
            hold(nil)
        }
    }

    /// Not a `Button`: a button fires on finger-UP, which is the one moment a
    /// hold is already over. The pressed styling is therefore reproduced by
    /// hand from `PressableStyle` (same 0.6 / 0.95 / 0.12s), and VoiceOver —
    /// which activates without ever delivering a drag — gets an explicit
    /// button trait and a plain `press` as its action.
    private func directionButton(_ icon: String, _ key: KeyCommand, _ label: String) -> some View {
        let isPressed = pressedDirection == key
        return Image(systemName: icon)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(Theme.iconMuted)
            .frame(width: 48, height: 48)   // ≥44pt target; visuals unchanged
            .contentShape(Rectangle())
            .opacity(isPressed ? 0.6 : 1)
            .scaleEffect(isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.12), value: isPressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        // Idempotent by design — setHeldDirection no-ops on a
                        // repeat — so the guard is only about buzzing once.
                        guard pressedDirection != key else { return }
                        pressedDirection = key
                        Haptics.tap()
                        hold(key)
                    }
                    .onEnded { _ in
                        // Release FIRST and unconditionally. Nothing above it
                        // may be able to take an early return.
                        hold(nil)
                        pressedDirection = nil
                    }
            )
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { press(key) }
    }
}

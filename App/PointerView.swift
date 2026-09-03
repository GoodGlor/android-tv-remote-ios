import RemoteCore
import SwiftUI

/// Pointer mode: a drag sends real 2D deltas to the TV browser's cursor
/// service — any direction, any curve — and a tap clicks.
///
/// This view is reachable only while that service is live: `RemoteView`
/// hides the mode toggle and forces `mode` back to `.dpad` the instant
/// `cursor.isAvailable` goes false, so `PointerView` itself is never asked
/// to be shown without a working cursor underneath it. There is deliberately
/// no fallback mechanism here — the held-key glide that used to stand in for
/// a missing cursor was removed because a mode that is present but inert is
/// worse than absent: a user whose TV browser was closed got a pad that
/// looked usable and did nothing. This view holds no key and therefore owes
/// no release of one; `DPadView` is the only remaining key-holder.
struct PointerView: View {
    let cursor: any BrowserCursorControlling

    @State private var trackpad = TrackpadEngine()
    @State private var epoch = ContinuousClock.now

    var body: some View {
        surface
            .gesture(trackpadGesture)
            .onDisappear {
                trackpad.cancel()
            }
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
            .accessibilityLabel("Trackpad — drag to move the cursor freely, tap to click")
    }

    private var caption: some View {
        VStack(spacing: 10) {
            Image(systemName: "cursorarrow")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Theme.accent)
            Text("Drag to move")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text("Free cursor · tap to click")
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent.opacity(0.8))
        }
    }

    /// Relative deltas straight to the browser.
    private var trackpadGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if let delta = trackpad.moved(to: value.location, now: epoch.duration(to: .now)) {
                    cursor.move(dx: Float(delta.dx), dy: Float(delta.dy))
                }
            }
            .onEnded { value in
                let release = trackpad.ended(at: value.location, now: epoch.duration(to: .now))
                if let flush = release.flush {
                    cursor.move(dx: Float(flush.dx), dy: Float(flush.dy))
                }
                if release.isTap {
                    Haptics.tap()
                    cursor.click()
                }
            }
    }
}

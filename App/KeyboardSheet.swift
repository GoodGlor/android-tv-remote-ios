import RemoteCore
import SwiftUI

/// Live mirror of the TV's focused text field. The phone field initializes
/// from the TV value; local edits push the FULL string (debounced) through
/// the controller's clear+append write; TV-side edits stream back in and
/// update the phone when it isn't mid-edit. Absolute values on both sides —
/// no deltas, no drift (the Phase 2 delta bug class is structurally gone).
struct KeyboardSheet: View {
    let controller: any TVController
    @Binding var isPresented: Bool

    @State private var text = ""
    @State private var pushTask: Task<Void, Never>?
    /// The value a still-debouncing push will send. Kept so a dismissal can
    /// FLUSH it rather than drop it (see `.onDisappear`).
    @State private var pendingPush: String?
    /// The last value `text` took from — or handed to — the TV. `text` serves
    /// two roles (mirroring a TV field, and composing a search query with no
    /// field focused), and this is how they are told apart: if `text` has
    /// drifted from this baseline the user composed something, and a field the
    /// TV focuses later must NOT overwrite it.
    @State private var tvBaseline = ""
    @FocusState private var focused: Bool

    private var field: TextFieldStatus? { controller.focusedTextField }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(field.map { $0.hint.isEmpty ? "Type to your TV" : $0.hint }
                     ?? "No text field on TV")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Text("Done")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
            }

            // Deliberately not `.disabled`/dimmed when `field == nil`: Task 5
            // composes a search query locally with no TV field required, so
            // the field stays editable regardless. The caption below and the
            // tile's icon color are what communicate TV-field availability.
            TextField("", text: $text)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.accent)
                .focused($focused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(Theme.sheetBackground, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .padding(.top, 12)
                .accessibilityLabel("Text on your TV")
                .onChange(of: text) { _, newValue in
                    guard field != nil, newValue != field?.value else { return }
                    // Debounce ≥120ms so bursts coalesce before the two-edit
                    // write; ImeChannel serializes and keeps only the latest.
                    pushTask?.cancel()
                    pendingPush = newValue
                    pushTask = Task {
                        try? await Task.sleep(for: .milliseconds(150))
                        guard !Task.isCancelled else { return }
                        push(newValue)
                        pushTask = nil   // a completed push no longer blocks TV-side adoption
                    }
                }
                .onChange(of: field) { _, newField in
                    guard let newField else { return }
                    // NEVER adopt our OWN transient intermediate. A write is
                    // clear-then-append (this firmware has no working range
                    // replace), and the TV echoes the field EMPTY between the
                    // two edits. Adopting that wiped the box mid-typing:
                    // `одісея` typed fast showed `о`, then `од`, and ended at
                    // `ея` — every keystroke landing in the wiped window built
                    // on "" instead of on what the user had typed. Neither
                    // guard below catches it (`pushTask` is nil the moment the
                    // debounced push goes out, and `push` moves `tvBaseline` to
                    // the value it sends), and the value alone cannot be judged
                    // — an empty absolute status is exactly what a legitimate
                    // TV-side clear looks like too. So the transport says when
                    // a status belongs to a write of ours, and we sit those
                    // out entirely; once the write settles, echoes adopt as
                    // normal, and absolute statuses make any skipped one
                    // self-correct on the next.
                    guard !controller.isWriteInFlight else { return }
                    // TV-side change (physical remote, or our own echo):
                    // adopt it unless a local push is still pending. A
                    // cancelled task never reaches the `pushTask = nil` line
                    // above (it returns early on the cancellation check), so
                    // it can't fool this guard into adopting mid-keystroke —
                    // `pushTask` only reads nil once a push has genuinely
                    // gone out with nothing newer superseding it.
                    guard pushTask == nil || pushTask!.isCancelled || newField.value == text
                    else { return }
                    // ...and unless the user has composed something of their
                    // own. Typing a search query while NOTHING is focused
                    // skips the push (`guard field != nil` above), so the
                    // moment the TV focused a field the old code adopted its
                    // value and silently destroyed the query. Divergence from
                    // the baseline means the text is the user's, and theirs
                    // wins until they send it or clear the box.
                    guard text.isEmpty || text == tvBaseline else { return }
                    text = newField.value
                    tvBaseline = newField.value
                }

            Text(field == nil
                 ? "Focus a text field on the TV (its keyboard must be open)"
                 : "Mirrored live — typing here edits \(appLabel(field!.packageName))")
                .font(.system(size: 12))
                .foregroundStyle(Theme.sheetPlaceholder)
                .padding(.top, 10)

            // Search needs no TV-side field: both routes go out as deep links.
            // So these stay usable exactly when there is something to search
            // for. Two buttons, splitting the row evenly — each `Label` takes
            // `maxWidth: .infinity` inside a ≥44pt-tall tappable frame.
            HStack(spacing: 10) {
                searchButton("YouTube", systemImage: "play.rectangle") {
                    controller.search(text, target: .youtube)
                }
                searchButton("Web", systemImage: "globe") {
                    controller.search(text, target: .web)
                }
            }
            .padding(.top, 14)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .presentationDetents([.height(240)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.sheet)
        .onAppear {
            text = field?.value ?? ""
            tvBaseline = text
            // Focused even with no TV field: the box doubles as the search
            // composer, so there is always something to type.
            focused = true
        }
        .onDisappear {
            // FLUSH, don't drop. Dismissing inside the 150ms debounce window
            // used to cancel the push and lose the user's last edit outright.
            pushTask?.cancel()
            pushTask = nil
            if let pending = pendingPush { push(pending) }
        }
    }

    /// The one place an edit leaves for the TV. Moves the baseline with it, so
    /// the TV's echo of this very value still reads as "not diverged".
    private func push(_ value: String) {
        pendingPush = nil
        guard field != nil else { return }
        tvBaseline = value
        controller.setText(value)
    }

    private func searchButton(_ title: String, systemImage: String,
                              action: @escaping () -> Void) -> some View {
        Button {
            // DROP the pending mirror push rather than let `.onDisappear`
            // flush it: the user tapped Search, not Done, so the intent is
            // "search for this", not "type this into whatever TV field
            // happens to be focused". Cancel the in-flight debounce task
            // too — left running, it would land the write on its own timer
            // a moment later regardless of the sheet being dismissed.
            pushTask?.cancel()
            pushTask = nil
            pendingPush = nil
            action()
            isPresented = false
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(text.isEmpty ? Theme.iconMuted : Theme.accent)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(PressableStyle())
        .disabled(text.isEmpty)
    }

    private func appLabel(_ package: String) -> String {
        package.split(separator: ".").last.map(String.init) ?? package
    }
}

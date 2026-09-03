import Foundation
import RemoteCore

// rc-probe — debug harness. Drives the same session layer the app uses,
// printing every event. Run it via ./Scripts/probe.sh, which supplies the
// macOS deployment-target flag the dependency forces:
//   ./Scripts/probe.sh discover
//   ./Scripts/probe.sh pair 192.168.0.103
//   ./Scripts/probe.sh key  192.168.0.103 down
//   ./Scripts/probe.sh raw  192.168.0.103 176      (any Android keycode)
//   ./Scripts/probe.sh text 192.168.0.103 hello
//   ./Scripts/probe.sh dump 192.168.0.103            (listen; see what the TV sends)\n//   ./Scripts/probe.sh decode < dump.log             (re-annotate a dump offline)\n//   ./Scripts/probe.sh settext 192.168.0.103 hi      (IME write spike)

// Unbuffered stdout: this tool's whole value is seeing events AS THEY HAPPEN.
// When stdout is a pipe or file, Swift block-buffers it, so a run that is
// killed or hangs shows nothing at all — which reads as "no events" when the
// truth may be "events happened and were lost in the buffer".
setvbuf(stdout, nil, _IONBF, 0)

/// Reads one line from stdin off the MainActor. `readLine()` blocks its
/// calling thread for as long as the user takes to type; calling it directly
/// from a MainActor-isolated context would freeze that actor's executor and
/// starve any other MainActor work — including a timeout `Task.sleep` — of
/// the chance to resume on schedule. Hopping to a detached task keeps the
/// MainActor free while we wait on stdin.
func readCodeFromStdin() async -> String? {
    await Task.detached {
        readLine()?.trimmingCharacters(in: .whitespaces).uppercased()
    }.value
}

@MainActor
func run() async {
    let arguments = CommandLine.arguments
    guard arguments.count >= 2 else {
        print("usage: rc-probe discover | pair <host> | key <host> <up|down|left|right|ok|back|home|volumeUp|volumeDown|mute|power>")
        exit(64)
    }
    guard let identity = IdentityProvider.bundled() else {
        print("FATAL: bundled identity missing — run Scripts/generate-identity.sh")
        exit(70)
    }

    switch arguments[1] {
    case "discover":
        let discovery = DeviceDiscovery()
        discovery.start()
        print("browsing _androidtvremote2._tcp for 10s…")
        try? await Task.sleep(for: .seconds(10))
        for device in discovery.devices {
            print("  \(device.name) @ \(device.host)")
        }
        print(discovery.devices.isEmpty ? "nothing found" : "done")

    case "pair":
        guard arguments.count >= 3 else { print("pair <host>"); exit(64) }
        let session = LibPairingSession(identity: identity)
        session.onEvent = { event in
            print("pairing event: \(event)")
            switch event {
            case .codeDisplayed:
                print("→ TV should be showing a 6-char code. Type it:")
                // Reading stdin happens off the MainActor (see
                // readCodeFromStdin) so a slow typist never blocks the
                // 120s timeout below from firing on schedule.
                Task { @MainActor in
                    guard let code = await readCodeFromStdin() else {
                        print("⚠️ stdin closed before a code was entered — pairing cannot continue automatically; waiting for timeout.")
                        return
                    }
                    session.sendCode(code)
                }
            case .paired:
                print("✅ PAIRED"); exit(0)
            case .failed(let error):
                print("❌ \(error)"); exit(1)
            }
        }
        print("pairing with \(arguments[2])…")
        session.start(host: arguments[2])
        try? await Task.sleep(for: .seconds(120))
        print("timed out"); exit(1)

    case "key":
        guard arguments.count >= 4 else { print("key <host> <name>"); exit(64) }
        let commands: [String: KeyCommand] = [
            "up": .up, "down": .down, "left": .left, "right": .right,
            "ok": .ok, "back": .back, "home": .home, "power": .power,
            "volumeUp": .volumeUp, "volumeDown": .volumeDown, "mute": .mute,
            "menu": .menu, "input": .input, "channelUp": .channelUp,
            "channelDown": .channelDown, "rewind": .rewind,
            "playPause": .playPause, "fastForward": .fastForward,
        ]
        guard let command = commands[arguments[3]] else { print("unknown key"); exit(64) }
        let session = LibControlSession(identity: identity)
        session.onEvent = { event in
            print("control event: \(event)")
            if case .connected = event {
                print("sending \(arguments[3])…")
                session.sendKey(command)
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    session.disconnect()
                    print("✅ sent"); exit(0)
                }
            }
        }
        session.connect(host: arguments[2])
        try? await Task.sleep(for: .seconds(30))
        print("timed out — no control event arrived"); exit(1)

    // Debug commands for trying things against a real TV without touching the
    // app: `raw` sends any Android keycode, `text` exercises text entry.
    // MEASUREMENT: how small a gap between key events does this TV actually
    // tolerate? The 80ms figure was tuned for sendText and never re-measured
    // for hold/release, and a direction change pays it on every drag.
    // Reproduces the real pattern — release(prev), hold(next) — at a fixed gap
    // and reports whether the session survived.
    case "pace":
        guard arguments.count >= 4 else { print("pace <host> <gapMs> [pairs]"); exit(64) }
        guard let gapMs = Int(arguments[3]) else { print("gapMs must be a number"); exit(64) }
        let pairs = arguments.count > 4 ? (Int(arguments[4]) ?? 12) : 12
        let paceSession = LibControlSession(identity: identity)
        var dropped = false
        paceSession.onEvent = { event in
            if case .dropped(let error) = event {
                dropped = true
                print("❌ DROPPED at gap \(gapMs)ms — \(String(describing: error))")
                exit(2)
            }
            if case .connected = event {
                Task { @MainActor in
                    print("→ \(pairs) direction changes at \(gapMs)ms gap")
                    let keys: [KeyCommand] = [.up, .down]
                    var held: KeyCommand?
                    for index in 0..<pairs {
                        let next = keys[index % keys.count]
                        if let previous = held { paceSession.releaseKey(previous) }
                        try? await Task.sleep(for: .milliseconds(gapMs))
                        paceSession.holdKey(next)
                        held = next
                        try? await Task.sleep(for: .milliseconds(gapMs))
                    }
                    if let previous = held { paceSession.releaseKey(previous) }
                    // Let a delayed RST surface before declaring success.
                    try? await Task.sleep(for: .seconds(3))
                    if !dropped { print("✅ SURVIVED gap \(gapMs)ms") }
                    paceSession.disconnect()
                    exit(dropped ? 2 : 0)
                }
            }
        }
        paceSession.connect(host: arguments[2])
        try? await Task.sleep(for: .seconds(120))
        print("timed out"); exit(1)

    case "raw", "text", "long", "link", "diag":
        guard arguments.count >= 4 else {
            print("raw <host> <keycode…> | long <host> <keycode> | diag <host> <code1> <code2> [ms] | text <host> <string> | link <host> <uri…>")
            exit(64)
        }
        let payload = arguments[3]
        let session = LibControlSession(identity: identity)
        session.onEvent = { event in
            print("control event: \(event)")
            if case .connected = event {
                Task { @MainActor in
                    if arguments[1] == "link" {
                        for uri in arguments.dropFirst(3) {
                            print("→ launching \(uri)  (watch the TV)")
                            session.sendDeepLink(uri)
                            try? await Task.sleep(for: .seconds(5))
                        }
                    } else if arguments[1] == "long" {
                        guard let code = UInt(payload) else { print("keycode must be a number"); exit(64) }
                        // Optional hold duration: `long <host> <code> <ms>`.
                        // Android auto-repeats a held D-pad key, which is how
                        // a cursor glides rather than nudging — so the hold
                        // length is the thing under test, not a constant.
                        let holdMs = arguments.count > 4 ? (Int(arguments[4]) ?? 700) : 700
                        print("→ HOLDING keycode \(code) for \(holdMs)ms  (WATCH THE TV)")
                        session.sendRawKeyCodeHeld(code, milliseconds: holdMs)
                        try? await Task.sleep(for: .milliseconds(holdMs + 2000))
                    } else if arguments[1] == "diag" {
                        // Two directions held AT ONCE — the untested route to
                        // diagonal cursor movement. The diagonal KEYCODES
                        // (268-271) are rejected by the browser cursor, but two
                        // ordinary held arrows are a different mechanism and may
                        // simply sum.
                        //
                        // Staggered by 150ms because the 80ms pacing floor
                        // applies to these messages like any other: two downs
                        // back-to-back close the control session. The floor
                        // binds the RELEASES too, so the second hold is
                        // shortened rather than released alongside the first.
                        guard arguments.count > 4,
                              let first = UInt(payload),
                              let second = UInt(arguments[4]) else {
                            print("diag <host> <code1> <code2> [ms]"); exit(64)
                        }
                        let holdMs = arguments.count > 5 ? (Int(arguments[5]) ?? 4000) : 4000
                        print("→ HOLDING \(first) + \(second) TOGETHER for ~\(holdMs)ms  (WATCH THE TV)")
                        session.sendRawKeyCodeHeld(first, milliseconds: holdMs)
                        try? await Task.sleep(for: .milliseconds(150))
                        session.sendRawKeyCodeHeld(second, milliseconds: holdMs - 300)
                        try? await Task.sleep(for: .milliseconds(holdMs + 2000))
                    } else if arguments[1] == "raw" {
                        // Several codes in ONE session: the TV allows only one
                        // control connection at a time, so reconnecting per
                        // candidate is both slow and prone to being refused.
                        for argument in arguments.dropFirst(3) {
                            guard let code = UInt(argument) else {
                                print("keycode must be a number: \(argument)"); continue
                            }
                            print("→ sending keycode \(code)  (watch the TV)")
                            session.sendRawKeyCode(code)
                            // Tight enough to sweep hundreds of codes in a few
                            // minutes, loose enough that a reacting TV is
                            // visibly attributable to the code just sent.
                            try? await Task.sleep(for: .milliseconds(1500))
                        }
                    } else {
                        print("→ sending text \"\(payload)\"")
                        session.sendText(payload)
                        try? await Task.sleep(for: .seconds(2))
                    }
                    session.disconnect()
                    print("✅ done"); exit(0)
                }
            }
        }
        session.connect(host: arguments[2])
        // Generous: a sweep of many keycodes at 5s apart runs for minutes.
        try? await Task.sleep(for: .seconds(600))
        print("timed out"); exit(1)

    // SPIKE (throwaway): listens without sending, printing every message the
    // TV pushes, deframed and annotated by protobuf field number. Exists to
    // answer one question — does this TV report focused-text-field status, and
    // in which field? Pings are hidden unless --pings is passed, because they
    // arrive every few seconds and bury everything else.
    case "dump":
        guard arguments.count >= 3 else {
            print("dump <host> [--pings] [--key <code>…] [--link <uri>…]")
            exit(64)
        }
        let showPings = arguments.contains("--pings")
        // Sending from inside the listening session matters: the TV allows one
        // control connection at a time, so a separate `link` run could not
        // observe how this session reacts — including whether it is dropped.
        let linksToSend: [String] = {
            guard let flag = arguments.firstIndex(of: "--link") else { return [] }
            return Array(arguments[(flag + 1)...]).filter { !$0.hasPrefix("--") }
        }()
        let keysToSend: [UInt] = {
            guard let flag = arguments.firstIndex(of: "--key") else { return [] }
            return Array(arguments[(flag + 1)...]).prefix { !$0.hasPrefix("--") }.compactMap { UInt($0) }
        }()
        let session = LibControlSession(identity: identity)
        var buffer: [UInt8] = []
        var messageCount = 0
        let started = Date()

        session.onRawData = { data in
            buffer.append(contentsOf: data)
            for message in deframe(&buffer) {
                let isPing = message.first == 0x42
                guard showPings || !isPing else { continue }
                messageCount += 1
                let elapsed = String(format: "%7.3fs", Date().timeIntervalSince(started))
                print("\n[\(elapsed)] #\(messageCount)  \(message.count) bytes\n  raw: \(hex(message))")
                for line in annotate(message) { print(line) }
            }
        }
        session.onEvent = { event in
            print("control event: \(event)")
            if case .connected = event {
                guard !linksToSend.isEmpty || !keysToSend.isEmpty else {
                    print("""

                        👂 listening — nothing will be sent to the TV.
                           Focus a text field on the TV and type with the physical remote.
                           Ctrl-C when done.

                        """)
                    return
                }
                Task { @MainActor in
                    // A beat before the first send, so the connect-time burst
                    // of status messages is not tangled up with the reaction.
                    try? await Task.sleep(for: .seconds(3))
                    for code in keysToSend {
                        print("\n→ sending keycode \(code)   (watch the TV)")
                        session.sendRawKeyCode(code)
                        try? await Task.sleep(for: .seconds(6))
                    }
                    for uri in linksToSend {
                        print("\n→ sending app-link: \(uri)   (watch the TV)")
                        session.sendDeepLink(uri)
                        try? await Task.sleep(for: .seconds(8))
                    }
                    print("\n→ all sends done; still listening")
                }
            }
        }
        // Ctrl-C must close the socket properly. The TV allows one control
        // session and refuses new ones for a minute or two after a client
        // vanishes without disconnecting, which turns an impatient Ctrl-C
        // into a stalled next probe.
        signal(SIGINT, SIG_IGN)
        let interrupts = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupts.setEventHandler {
            print("\n— interrupted after \(messageCount) non-ping message(s); disconnecting —")
            session.disconnect()
            // A beat for the FIN to leave before the process does.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
        }
        interrupts.resume()

        session.connect(host: arguments[2])
        try? await Task.sleep(for: .seconds(600))
        print("\n— 10 minutes elapsed, \(messageCount) non-ping message(s) seen —")
        session.disconnect()
        try? await Task.sleep(for: .milliseconds(300))
        exit(0)

    // SPIKE: the write direction. Waits for a text field to be focused on the
    // TV (the TV announces it), then tries candidate ime_batch_edit shapes
    // until the TV echoes the text back as a field-22 status — the echo is
    // proof of acceptance, since the TV streams every real edit. A shape the
    // TV hates may drop the session; that is a result too.
    case "settext":
        guard arguments.count >= 4 else { print("settext <host> <text>"); exit(64) }
        let text = arguments[3]
        let session = LibControlSession(identity: identity)
        var buffer: [UInt8] = []
        var imeCounter: UInt64 = 1
        var fieldCounter: UInt64 = 0
        var statusCounter: UInt64 = 0
        var fieldSeen = false
        var echoed = false
        var editSent = false
        var imeStateArrived = false
        var lastValue = ""
        var valueBeforeEdit = ""

        session.onRawData = { data in
            buffer.append(contentsOf: data)
            for message in deframe(&buffer) {
                guard message.first != 0x42 else { continue }  // ping
                for field in wireFields(message) {
                    switch field.number {
                    case 21 where field.wire == 2:
                        let inner = wireFields(field.payload)
                        imeCounter = inner.first { $0.number == 1 }?.varint ?? imeCounter
                        fieldCounter = inner.first { $0.number == 2 }?.varint ?? fieldCounter
                        imeStateArrived = true
                        print("TV ime state: \(imeCounter) \(fieldCounter)")
                    case 20, 22:
                        guard field.wire == 2, let status = extractStatus(fromTopPayload: field.payload) else {
                            print("TV field \(field.number): app info only")
                            continue
                        }
                        statusCounter = status.counter
                        fieldSeen = true
                        print("TV status: counter=\(status.counter) value=\"\(status.value)\"")
                        // Any status change after our edit is the TV streaming
                        // the edit back — acceptance. Exact match additionally
                        // proves the replace semantics.
                        if editSent, status.value != valueBeforeEdit {
                            echoed = true
                            print(status.value == text
                                ? "✅ TV echoed exactly our text — replace CONFIRMED"
                                : "✅ field changed to \"\(status.value)\" — edit accepted (semantics differ)")
                        }
                        lastValue = status.value
                    default:
                        print("TV field \(field.number) (\(message.count) bytes)")
                    }
                }
            }
        }
        session.onEvent = { event in
            print("control event: \(event)")
            if case .dropped = event {
                print("❌ session dropped — the last shape sent is rejected by the TV")
                exit(2)
            }
            if case .connected = event {
                print("waiting for a focused text field on the TV…")
                Task { @MainActor in
                    for _ in 0..<120 {
                        if fieldSeen { break }
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    guard fieldSeen else { print("no text field appeared in 60s"); exit(1) }
                    try? await Task.sleep(for: .seconds(1))

                    // CONFIRMED sequence (found 2026-08-20 on the MiTV-MOSR1):
                    // a bare batch edit is silently ignored; the TV accepts it
                    // only after an ime_show_request echoing the focused
                    // field's status. The TV answers the show request with a
                    // field-21 message carrying the counters the edit must
                    // then use.
                    // The show request must carry an EMPTY value — echoing the
                    // field's text makes the TV ignore it (observed). And the
                    // edit must wait for the TV's field-21 reply: the counters
                    // it carries are the ones the edit is validated against.
                    // Three show-request forms, stopping at the first the TV
                    // answers (field-21 reply carries the edit's counters).
                    let showForms: [(String, Data)] = [
                        ("echo counter \(statusCounter)", imeShowRequest(statusCounter: statusCounter, value: "")),
                        ("counter 0", imeShowRequest(statusCounter: 0, value: "")),
                        ("empty", Data([0xba, 0x01, 0x00])),
                    ]
                    for (label, message) in showForms {
                        imeStateArrived = false
                        print("\n→ ime_show_request (\(label))")
                        session.sendRaw(message)
                        for _ in 0..<15 {
                            if imeStateArrived { break }
                            try? await Task.sleep(for: .milliseconds(150))
                        }
                        if imeStateArrived { break }
                    }
                    guard imeStateArrived else {
                        print("⚠️ TV answered no show-request form — not sending the edit")
                        session.disconnect()
                        try? await Task.sleep(for: .milliseconds(300))
                        exit(1)
                    }
                    // This firmware applies the NET length change at the
                    // cursor (observed): net-positive appends the value,
                    // net-negative deletes from the tail and ignores the
                    // value. So "set the field to X" is two edits: clear
                    // (delete current length), then append X.
                    valueBeforeEdit = lastValue
                    editSent = true
                    if !lastValue.isEmpty {
                        let clear = imeBatchEditReplace(
                            imeCounter: imeCounter, fieldCounter: fieldCounter,
                            currentLength: UInt64(lastValue.count), text: "")
                        print("→ edit 1: clear (delete \(lastValue.count)): \(hex(Array(clear)))")
                        session.sendRaw(clear)
                        try? await Task.sleep(for: .seconds(2))
                    }
                    let append = imeBatchEdit(
                        imeCounter: imeCounter, fieldCounter: fieldCounter, caret: 0, text: text)
                    print("→ edit 2: append \"\(text)\": \(hex(Array(append)))")
                    session.sendRaw(append)
                    try? await Task.sleep(for: .seconds(4))

                    // DIAGNOSTIC: does a SECOND write need its own
                    // show_request, or can it reuse the counters from the
                    // first handshake? The app currently handshakes per
                    // write and stops working after one; this decides it.
                    if arguments.contains("--twice") {
                        print("\n=== SECOND WRITE, NO NEW HANDSHAKE (reusing ime=\(imeCounter) field=\(fieldCounter)) ===")
                        let secondText = text + "2"
                        let before = lastValue
                        valueBeforeEdit = before
                        if !before.isEmpty {
                            print("→ edit 3: clear (delete \(before.count))")
                            session.sendRaw(imeBatchEditReplace(
                                imeCounter: imeCounter, fieldCounter: fieldCounter,
                                currentLength: UInt64(before.count), text: ""))
                            try? await Task.sleep(for: .seconds(2))
                        }
                        print("→ edit 4: append \"\(secondText)\"")
                        session.sendRaw(imeBatchEdit(
                            imeCounter: imeCounter, fieldCounter: fieldCounter, caret: 0, text: secondText))
                        try? await Task.sleep(for: .seconds(4))
                        print(lastValue == secondText
                            ? "✅ SECOND WRITE LANDED WITHOUT A NEW HANDSHAKE — one handshake covers many writes"
                            : "❌ second write did NOT land (field is \"\(lastValue)\") — each write needs its own handshake")
                    }
                    // Which keycode triggers the field's EDITOR ACTION (the
                    // on-screen keyboard's ✓ / search key)? D-pad centre just
                    // presses whatever on-screen key is highlighted, so it is
                    // not a submit. Try candidates in one session, spaced so
                    // the watcher can attribute the reaction.
                    if let flag = arguments.firstIndex(of: "--submit") {
                        let codes = Array(arguments[(flag + 1)...])
                            .prefix { !$0.hasPrefix("--") }.compactMap { UInt($0) }
                        for code in codes {
                            print("\n→ submit candidate: keycode \(code)   (WATCH THE TV — did the search run?)")
                            session.sendRawKeyCode(code)
                            try? await Task.sleep(for: .seconds(5))
                        }
                        print("\n— all submit candidates sent —")
                    }
                    print(echoed
                        ? "\n✅ WRITE DIRECTION VERIFIED — check the TV shows \"\(text)\""
                        : "\n⚠️ no echo and no drop — the TV silently ignored every shape")
                    session.disconnect()
                    try? await Task.sleep(for: .milliseconds(300))
                    exit(echoed ? 0 : 1)
                }
            }
        }
        session.connect(host: arguments[2])
        try? await Task.sleep(for: .seconds(180))
        session.disconnect()
        exit(1)

    // Re-decodes a previous dump offline: feed it a log on stdin and it
    // re-annotates every `raw:` line with the current decoder. Needs no TV,
    // so improving the decoder never costs a reconnect.
    case "decode":
        while let line = readLine() {
            guard let range = line.range(of: "raw: ") else { continue }
            let bytes = line[range.upperBound...]
                .split(separator: " ")
                .compactMap { UInt8($0, radix: 16) }
            guard !bytes.isEmpty else { continue }
            print("\n\(bytes.count) bytes: \(hex(bytes))")
            for annotated in annotate(bytes) { print(annotated) }
        }
        exit(0)

    default:
        print("unknown command \(arguments[1])"); exit(64)
    }
}

await Task { @MainActor in await run() }.value

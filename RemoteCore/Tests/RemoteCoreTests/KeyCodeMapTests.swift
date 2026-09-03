import Testing
@preconcurrency import AndroidTVRemoteControl
@testable import RemoteCore

@Test func everyNonAppCommandMapsToAKeycode() {
    let commands: [KeyCommand] = [
        .power, .up, .down, .left, .right, .ok, .back, .home, .menu,
        .volumeUp, .volumeDown, .mute, .channelUp, .channelDown,
        .rewind, .playPause, .fastForward, .input,
    ]
    for command in commands {
        #expect(KeyCodeMap.key(for: command) != nil, "unmapped: \(command)")
    }
}

@Test func spotCheckAndroidKeycodeValues() {
    #expect(KeyCodeMap.key(for: .ok) == .KEYCODE_DPAD_CENTER)
    #expect(KeyCodeMap.key(for: .mute) == .KEYCODE_VOLUME_MUTE)
    #expect(KeyCodeMap.key(for: .playPause) == .KEYCODE_MEDIA_PLAY_PAUSE)
    #expect(KeyCodeMap.key(for: .input) == .KEYCODE_TV_INPUT)
    #expect(KeyCodeMap.key(for: .launchApp(.netflix)) == nil)
}

// Verified against a Xiaomi TV P1e 32: KEYCODE_MENU (82), SETTINGS (176),
// APP_SWITCH (187) and ALL_APPS (284) were all accepted and silently ignored.
// A long press of OK is the only thing that opens a context menu.
@Test func menuIsALongPressOfOK() {
    #expect(KeyCodeMap.key(for: .menu) == .KEYCODE_DPAD_CENTER)
    #expect(KeyCodeMap.usesLongPress(.menu))
}

@Test func onlyMenuUsesLongPress() {
    let others: [KeyCommand] = [
        .power, .up, .down, .left, .right, .ok, .back, .home,
        .volumeUp, .volumeDown, .mute, .channelUp, .channelDown,
        .rewind, .playPause, .fastForward, .input,
        .launchApp(.netflix),
    ]
    for command in others {
        #expect(!KeyCodeMap.usesLongPress(command), "unexpected long press: \(command)")
    }
}

// OK and menu share a keycode and are told apart only by press duration —
// so a regression that dropped the long press would turn menu into a plain OK.
@Test func okAndMenuShareAKeycodeButNotADuration() {
    #expect(KeyCodeMap.key(for: .ok) == KeyCodeMap.key(for: .menu))
    #expect(KeyCodeMap.usesLongPress(.ok) != KeyCodeMap.usesLongPress(.menu))
}

@Test func appShortcutsHaveLinks() {
    for app in AppShortcut.allCases {
        #expect(!KeyCodeMap.appLink(for: app).isEmpty)
    }
}

@Test func asciiTextMapsToKeySequence() {
    #expect(KeyCodeMap.asciiKeys(for: "ab 1") ==
        [.KEYCODE_A, .KEYCODE_B, .KEYCODE_SPACE, .KEYCODE_1])
    // Unsupported characters (incl. Cyrillic) are skipped, not errors.
    #expect(KeyCodeMap.asciiKeys(for: "п") == [])
}

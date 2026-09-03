import Testing
@testable import RemoteCore
@preconcurrency import AndroidTVRemoteControl

@Test func packageBuilds() {
    #expect(Bool(true))
}

@Test func libraryKeycodesAreReachable() {
    #expect(Key.KEYCODE_DPAD_UP.rawValue == 19)
    #expect(Key.KEYCODE_VOLUME_MUTE.rawValue == 164)
}

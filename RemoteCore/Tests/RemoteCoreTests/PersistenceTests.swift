import Foundation
import Testing
@testable import RemoteCore

private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "test-\(UUID().uuidString)")!
}

@Test func deviceStoreRoundTripsAndClears() {
    let store = DeviceStore(defaults: freshDefaults())
    #expect(store.pairedDevice == nil)

    let device = PairedDevice(name: "Xiaomi TV P1e 32", host: "192.168.31.24", serviceName: "Xiaomi TV P1e 32")
    store.save(device)
    #expect(store.pairedDevice == device)

    store.clear()
    #expect(store.pairedDevice == nil)
}

@Test func legacyStoredDeviceWithoutServiceNameIsDiscarded() {
    let defaults = freshDefaults()
    defaults.set(Data(#"{"name":"TV","host":"10.0.0.2"}"#.utf8), forKey: "pairedDevice")
    let store = DeviceStore(defaults: defaults)
    #expect(store.pairedDevice == nil)
}

@Test func hapticsDefaultOnAndPersist() {
    let defaults = freshDefaults()
    let prefs = Preferences(defaults: defaults)
    #expect(prefs.hapticsEnabled == true)

    prefs.hapticsEnabled = false
    #expect(Preferences(defaults: defaults).hapticsEnabled == false)
}

@Test func controlModeDefaultsToDpad() {
    let prefs = Preferences(defaults: freshDefaults())
    #expect(prefs.controlMode == .dpad)
}

@Test func controlModeIsExactlyDpadAndPointer() {
    #expect(ControlMode.allCases == [.dpad, .pointer])
}

/// The Phase 1 Bool only ever selected the swipe mode, which no longer
/// exists. `true` must therefore land on `.dpad` — never crash, never leave
/// `controlMode` unresolvable.
@Test func controlModeIgnoresTheLegacySwipeModeBool() {
    let defaults = freshDefaults()
    let prefs = Preferences(defaults: defaults)
    defaults.set(true, forKey: "lastModeIsTouchpad")
    #expect(prefs.controlMode == .dpad)

    prefs.controlMode = .pointer // an explicit choice wins forever
    #expect(prefs.controlMode == .pointer)
    #expect(Preferences(defaults: defaults).controlMode == .pointer)
}

/// The other half of the same migration: users who had already been moved to
/// the string key have "touchpad" stored. An unknown raw value must resolve to
/// the default, not to nil.
@Test func controlModeResolvesTheRemovedStoredModeToDpad() {
    let defaults = freshDefaults()
    defaults.set("touchpad", forKey: "controlMode")
    let prefs = Preferences(defaults: defaults)
    #expect(prefs.controlMode == .dpad)

    prefs.controlMode = .pointer
    #expect(Preferences(defaults: defaults).controlMode == .pointer)
}

// MARK: - effectiveControlMode

/// Pointer is never offered without a live cursor: a pad that draws but
/// cannot move anything is worse than no pad at all.
@Test func effectiveControlModeKeepsPointerWhenAvailable() {
    #expect(effectiveControlMode(.pointer, cursorAvailable: true) == .pointer)
}

/// A persisted `.pointer` is a preference, not a promise — the cursor may
/// not be reachable this session (browser closed, TV just booted).
@Test func effectiveControlModeDropsPersistedPointerWhenUnavailable() {
    #expect(effectiveControlMode(.pointer, cursorAvailable: false) == .dpad)
}

/// `.dpad` never depends on the cursor and always resolves to itself.
@Test func effectiveControlModeKeepsDpadWhenUnavailable() {
    #expect(effectiveControlMode(.dpad, cursorAvailable: false) == .dpad)
}

/// The mid-session case: availability drops while the user is already in
/// `.pointer` — must fall back to `.dpad`, never leave a pad that cannot do
/// anything on screen.
@Test func effectiveControlModeFallsBackWhenAvailabilityDropsWhileInPointer() {
    #expect(effectiveControlMode(.pointer, cursorAvailable: false) == .dpad)
}

// MARK: D-pad style

@Test func dpadStyleDefaultsToButtonsWhenUnset() {
    let defaults = UserDefaults(suiteName: "dpadStyle.unset")!
    defaults.removePersistentDomain(forName: "dpadStyle.unset")
    // Existing users must not be moved onto a new surface by an upgrade.
    #expect(Preferences(defaults: defaults).dpadStyle == .buttons)
}

@Test func dpadStyleRoundTrips() {
    let defaults = UserDefaults(suiteName: "dpadStyle.roundtrip")!
    defaults.removePersistentDomain(forName: "dpadStyle.roundtrip")
    let preferences = Preferences(defaults: defaults)
    preferences.dpadStyle = .trackpad
    #expect(Preferences(defaults: defaults).dpadStyle == .trackpad)
}

@Test func anUnknownStoredDpadStyleFallsBackToButtons() {
    let defaults = UserDefaults(suiteName: "dpadStyle.garbage")!
    defaults.removePersistentDomain(forName: "dpadStyle.garbage")
    defaults.set("joystick", forKey: "dpadStyle")
    // A value from a future or abandoned build must not strand the user with
    // no D-pad at all.
    #expect(Preferences(defaults: defaults).dpadStyle == .buttons)
}

@Test func dpadStyleAndControlModeAreIndependent() {
    let defaults = UserDefaults(suiteName: "dpadStyle.independent")!
    defaults.removePersistentDomain(forName: "dpadStyle.independent")
    let preferences = Preferences(defaults: defaults)
    preferences.dpadStyle = .trackpad
    preferences.controlMode = .pointer
    // Two orthogonal choices sharing one screen: switching the D-pad's
    // appearance must not silently change which mode the remote is in.
    #expect(preferences.dpadStyle == .trackpad)
    #expect(preferences.controlMode == .pointer)
}

@Test func trackpadAccelerationDefaultsToOff() {
    let defaults = UserDefaults(suiteName: "accel.unset")!
    defaults.removePersistentDomain(forName: "accel.unset")
    // Off by default: one swipe, one step. On, a single swipe skips tiles.
    #expect(Preferences(defaults: defaults).trackpadAcceleration == false)
}

@Test func trackpadAccelerationSurvivesAStyleChange() {
    let defaults = UserDefaults(suiteName: "accel.roundtrip")!
    defaults.removePersistentDomain(forName: "accel.roundtrip")
    let preferences = Preferences(defaults: defaults)
    preferences.trackpadAcceleration = true
    preferences.dpadStyle = .buttons
    preferences.dpadStyle = .trackpad
    // The setting is only meaningful for the trackpad, but visiting the
    // buttons and coming back must not silently reset it.
    #expect(preferences.trackpadAcceleration)
}

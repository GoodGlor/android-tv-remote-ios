# Phase 2 — Real Android TV Connectivity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `MockTVController` behind the `TVController` seam with a real Android TV Remote protocol v2 implementation (mDNS discovery, TLS pairing with on-screen code, key/app control) for the Xiaomi TV P1e 32 and any Android TV device.

**Architecture:** All protocol bytes come from the pinned `AndroidTVRemoteControl` package (MIT). We write app plumbing only: a bundled RSA identity, NWBrowser discovery, thin `@MainActor`-safe session wrappers around the library's callback API, an `AndroidTVController` adapter implementing the revised `TVController` protocol, a macOS CLI harness (`rc-probe`), and the Connect-screen pairing flow. Only Sendable event enums cross from library callbacks onto the MainActor.

**Tech Stack:** Swift 6 / SwiftUI / Swift Testing, SPM, [AndroidTVRemoteControl @ `32393c3`](https://github.com/odyshewroman/AndroidTVRemoteControl), Network.framework (NWBrowser), Security.framework (SecPKCS12Import), openssl (dev-time only), XcodeGen.

**Spec:** `docs/superpowers/specs/2026-08-19-tv-remote-phase2-design.md`

## Global Constraints

- Every `swift` / `xcodebuild` / `xcrun` command MUST be prefixed with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (system xcode-select points at CommandLineTools).
- Package tests: **`./Scripts/test.sh`** from the repo root (never bare `swift test`).
  The dependency declares only `platforms: [.iOS(.v13)]`, so SwiftPM builds it
  against macOS 10.13 where CryptoKit's `SHA256` does not exist and compilation
  fails. The script forces the macOS deployment target for the whole graph.
  Same flag is needed for `swift run rc-probe`:
  `swift run -Xswiftc -target -Xswiftc "$(uname -m)-apple-macosx14.0" rc-probe …`
- Dependency rule: Apple platforms + **exactly one** external package, `AndroidTVRemoteControl`, pinned to revision `32393c3`. No other packages, ever.
- After adding/removing any file under `App/`, run `xcodegen generate` before building. `RemoteControl.xcodeproj` and (after Task 9) `App/Info.plist` are generated and git-ignored.
- Visual design is locked: accent `#FF8B3D`, dark theme, D-pad default, text-only tiles, portrait iPhone, iOS 17+. Do not change visuals; hit areas stay ≥44pt (`max(size, 44)` + `contentShape`).
- Class/type names are Android-TV-flavoured, never Xiaomi-flavoured.
- The library is pre-strict-concurrency: use `@preconcurrency import AndroidTVRemoteControl`. Map library states to our Sendable event enums *synchronously inside library callbacks*; only Sendable values may be sent to the MainActor. If strict-concurrency errors persist anywhere, fallback is `.swiftLanguageMode(.v5)` in `swiftSettings` for the RemoteCore target — do not restructure the design around a warning.
- Simulator smoke test after UI tasks: build + install + launch per `docs/HANDOFF.md` "How to run".
- App commit trailer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## File Structure

```
Scripts/generate-identity.sh                     NEW  dev-time RSA cert generation
RemoteCore/Package.swift                         MOD  dependency, resources, rc-probe target
RemoteCore/Sources/RemoteCore/
  Resources/client.p12, client.der               NEW  committed identity artifacts
  IdentityProvider.swift                         NEW  bundled identity URLs + password
  TVController.swift                             MOD  protocol v2, TVControllerError, serviceName
  MockTVController.swift                         MOD  new protocol shape
  KeyCodeMap.swift                               NEW  KeyCommand→Key, app links, ASCII text→keys
  DeviceDiscovery.swift                          NEW  NWBrowser + endpoint resolution
  Sessions.swift                                 NEW  PairingSessioning/ControlSessioning protocols + events + state mapping
  LibSessions.swift                              NEW  library-backed session implementations
  AndroidTVController.swift                      NEW  the adapter (implements TVController)
RemoteCore/Sources/rc-probe/main.swift           NEW  macOS CLI harness
RemoteCore/Tests/RemoteCoreTests/
  IdentityProviderTests.swift                    NEW
  KeyCodeMapTests.swift                          NEW
  SessionMappingTests.swift                      NEW
  AndroidTVControllerTests.swift                 NEW  (uses fake sessions)
  MockTVControllerTests.swift, PersistenceTests.swift  MOD  new protocol shape
App/RemoteControlApp.swift                       MOD  real controller, scenePhase policy
App/ConnectView.swift                            MOD  begin-pairing flow, hex code, permission UX
App/SettingsView.swift                           MOD  live badge, accessibility
App/RemoteView.swift, KeyboardSheet.swift, Components.swift, Theme.swift  MOD  accessibility + color consolidation
project.yml                                      MOD  info: block (Bonjour/local-network keys)
docs/phase2-dinner-checklist.md                  NEW  manual TV verification protocol
```

---

### Task 1: Pin the library dependency

**Files:**
- Modify: `RemoteCore/Package.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `import AndroidTVRemoteControl` available to RemoteCore targets; classes used later: `PairingManager`, `RemoteManager`, `TLSManager`, `CryptoManager`, `CertManager`, `Key`, `KeyPress`, `DeepLink`, `CommandNetwork.DeviceInfo`, `AndroidTVRemoteControlError`.

- [ ] **Step 1: Add the dependency and a probe of the import**

Replace `RemoteCore/Package.swift` content with:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RemoteCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "RemoteCore", targets: ["RemoteCore"])],
    dependencies: [
        // The ONLY external dependency. Pinned by revision: latest tag (2.4.16,
        // Aug 2024) predates the connection-timeout feature on main.
        .package(
            url: "https://github.com/odyshewroman/AndroidTVRemoteControl",
            revision: "32393c3"
        ),
    ],
    targets: [
        .target(
            name: "RemoteCore",
            dependencies: [
                .product(name: "AndroidTVRemoteControl", package: "AndroidTVRemoteControl"),
            ]
        ),
        .testTarget(name: "RemoteCoreTests", dependencies: ["RemoteCore"]),
    ]
)
```

- [ ] **Step 2: Write a failing smoke test that touches the library**

Append to `RemoteCore/Tests/RemoteCoreTests/SmokeTests.swift`:

```swift
@preconcurrency import AndroidTVRemoteControl

@Test func libraryKeycodesAreReachable() {
    #expect(Key.KEYCODE_DPAD_UP.rawValue == 19)
    #expect(Key.KEYCODE_VOLUME_MUTE.rawValue == 164)
}
```

- [ ] **Step 3: Run tests — expect resolution + pass**

Run: `./Scripts/test.sh`
Expected: dependency resolves to revision 32393c3, all existing tests + the new one PASS. (First run downloads the package.)

- [ ] **Step 4: Verify the iOS app still builds**

Run (repo root):
```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
xcodebuild -project RemoteControl.xcodeproj -scheme RemoteControl \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/rc-build build
```
Expected: BUILD SUCCEEDED (Xcode resolves the local package's remote dependency automatically).

- [ ] **Step 5: Commit**

```bash
git add RemoteCore/Package.swift RemoteCore/Package.resolved RemoteCore/Tests/RemoteCoreTests/SmokeTests.swift
git commit -m "feat: pin AndroidTVRemoteControl dependency at 32393c3"
```
(If `Package.resolved` appears at a different path, add it from wherever SwiftPM wrote it — it must be committed for reproducible resolution.)

---

### Task 2: Client identity — generation script, artifacts, IdentityProvider

**Files:**
- Create: `Scripts/generate-identity.sh`
- Create: `RemoteCore/Sources/RemoteCore/Resources/client.p12`, `RemoteCore/Sources/RemoteCore/Resources/client.der` (generated, committed)
- Create: `RemoteCore/Sources/RemoteCore/IdentityProvider.swift`
- Modify: `RemoteCore/Package.swift` (resources)
- Test: `RemoteCore/Tests/RemoteCoreTests/IdentityProviderTests.swift`

**Interfaces:**
- Consumes: library's `CertManager` (`cert(_ url: URL, _ password: String) -> Result<CFArray?>`, `getSecKey(_ url: URL) -> Result<SecKey>`).
- Produces: `IdentityProvider` struct: `p12URL: URL`, `publicCertURL: URL`, `password: String`, `static func bundled() -> IdentityProvider?`. Used by Tasks 5, 7.

**Why RSA + these openssl flags:** the library's `CryptoManager` computes the pairing secret from RSA modulus/exponent and returns `.notRSAKey` for anything else. OpenSSL 3's default PKCS#12 encryption (AES/PBES2) is rejected by some `SecPKCS12Import` versions; SHA1-3DES is universally accepted and fine here (the p12 password protects nothing secret — the identity only authenticates the remote to a TV on your own LAN).

- [ ] **Step 1: Write the generation script**

`Scripts/generate-identity.sh`:

```bash
#!/bin/bash
# Generates the app's single client identity for Android TV pairing.
# Run ONCE (artifacts are committed); re-run only to rotate the identity,
# which un-pairs every TV.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)/RemoteCore/Sources/RemoteCore/Resources"
mkdir -p "$DIR"
cd "$DIR"

# RSA-2048 is REQUIRED: the pairing secret hash uses RSA modulus/exponent.
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout client.key -out client.pem \
  -subj "/CN=RemoteControl/O=artem"

openssl x509 -in client.pem -outform der -out client.der

# SHA1-3DES parameters: OpenSSL 3's AES default breaks SecPKCS12Import.
openssl pkcs12 -export -out client.p12 -inkey client.key -in client.pem \
  -passout pass:atvremote \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

rm client.key client.pem
echo "Generated $DIR/client.p12 and client.der"
```

Run: `chmod +x Scripts/generate-identity.sh && ./Scripts/generate-identity.sh`
Expected: both files exist under `RemoteCore/Sources/RemoteCore/Resources/`.

- [ ] **Step 2: Declare the resources in Package.swift**

In `RemoteCore/Package.swift`, change the main target to:

```swift
        .target(
            name: "RemoteCore",
            dependencies: [
                .product(name: "AndroidTVRemoteControl", package: "AndroidTVRemoteControl"),
            ],
            resources: [
                .copy("Resources/client.p12"),
                .copy("Resources/client.der"),
            ]
        ),
```

- [ ] **Step 3: Write the failing tests**

`RemoteCore/Tests/RemoteCoreTests/IdentityProviderTests.swift`:

```swift
import Foundation
import Security
import Testing
@preconcurrency import AndroidTVRemoteControl
@testable import RemoteCore

@Test func bundledIdentityResolvesBothArtifacts() throws {
    let identity = try #require(IdentityProvider.bundled())
    #expect(FileManager.default.fileExists(atPath: identity.p12URL.path))
    #expect(FileManager.default.fileExists(atPath: identity.publicCertURL.path))
}

// Running on macOS via `swift test`, this proves the exact bytes the app will
// ship import cleanly with Security.framework — the offline check that the
// openssl parameters are right.
@Test func p12ImportsViaSecurityFramework() throws {
    let identity = try #require(IdentityProvider.bundled())
    switch CertManager().cert(identity.p12URL, identity.password) {
    case .Result(let items): #expect(items != nil)
    case .Error(let error): Issue.record("SecPKCS12Import failed: \(error)")
    }
}

@Test func publicCertificateIsRSA() throws {
    let identity = try #require(IdentityProvider.bundled())
    switch CertManager().getSecKey(identity.publicCertURL) {
    case .Result(let key):
        let attrs = SecKeyCopyAttributes(key) as? [String: Any]
        #expect(attrs?[kSecAttrKeyType as String] as? String == (kSecAttrKeyTypeRSA as String))
    case .Error(let error): Issue.record("getSecKey failed: \(error)")
    }
}
```

Run: `./Scripts/test.sh --filter IdentityProvider`
Expected: FAIL — `IdentityProvider` not defined.

- [ ] **Step 4: Implement IdentityProvider**

`RemoteCore/Sources/RemoteCore/IdentityProvider.swift`:

```swift
import Foundation

/// The app's single client identity: a dev-time-generated RSA-2048 certificate
/// bundled as package resources (see Scripts/generate-identity.sh). One
/// identity for the whole app; every TV remembers it at pairing. Rotating the
/// files un-pairs all TVs.
public struct IdentityProvider: Sendable {
    public let p12URL: URL
    public let publicCertURL: URL
    public let password: String

    public init(p12URL: URL, publicCertURL: URL, password: String) {
        self.p12URL = p12URL
        self.publicCertURL = publicCertURL
        self.password = password
    }

    public static func bundled() -> IdentityProvider? {
        guard let p12 = Bundle.module.url(forResource: "client", withExtension: "p12"),
              let der = Bundle.module.url(forResource: "client", withExtension: "der")
        else { return nil }
        return IdentityProvider(p12URL: p12, publicCertURL: der, password: "atvremote")
    }
}
```

- [ ] **Step 5: Run the tests — expect pass**

Run: `./Scripts/test.sh`
Expected: all PASS, including the three new ones.

- [ ] **Step 6: Commit**

```bash
git add Scripts/generate-identity.sh RemoteCore/Sources/RemoteCore/Resources RemoteCore/Sources/RemoteCore/IdentityProvider.swift RemoteCore/Package.swift RemoteCore/Tests/RemoteCoreTests/IdentityProviderTests.swift
git commit -m "feat: add bundled RSA client identity with generation script"
```

---

### Task 3: TVController protocol v2, MockTVController, test migration

**Files:**
- Modify: `RemoteCore/Sources/RemoteCore/TVController.swift`
- Modify: `RemoteCore/Sources/RemoteCore/MockTVController.swift`
- Modify: `RemoteCore/Tests/RemoteCoreTests/MockTVControllerTests.swift`, `PersistenceTests.swift`, `DeviceTypesTests.swift` (wherever `DiscoveredDevice`/`PairedDevice` inits appear)
- Modify: `App/ConnectView.swift`, `App/RemoteControlApp.swift` — *minimal compile-keeping adaptation only; the real Connect UX is Task 10*

**Interfaces:**
- Consumes: nothing new.
- Produces (used by every later task):
  - `DiscoveredDevice { name: String, host: String, serviceName: String }` (id stays `host`)
  - `PairedDevice { name: String, host: String, serviceName: String }` (Codable)
  - `enum TVControllerError: Error, Equatable { case pairingFailed(String), wrongCode, connectionFailed(String), notPaired, cancelled }`
  - protocol `TVController` exactly as below.

- [ ] **Step 1: Rewrite the seam**

`RemoteCore/Sources/RemoteCore/TVController.swift`:

```swift
public struct DiscoveredDevice: Identifiable, Hashable, Sendable {
    public let name: String
    public let host: String
    /// Bonjour service instance name — the stable identity used to re-resolve
    /// the host when the router hands the TV a new IP.
    public let serviceName: String
    public var id: String { host }

    public init(name: String, host: String, serviceName: String) {
        self.name = name
        self.host = host
        self.serviceName = serviceName
    }
}

public struct PairedDevice: Codable, Equatable, Sendable {
    public let name: String
    public let host: String
    public let serviceName: String

    public init(name: String, host: String, serviceName: String) {
        self.name = name
        self.host = host
        self.serviceName = serviceName
    }
}

public enum ConnectionState: Equatable, Sendable {
    case disconnected, connecting, connected
}

public enum TVControllerError: Error, Equatable, Sendable {
    case pairingFailed(String)
    case wrongCode
    case connectionFailed(String)
    case notPaired
    case cancelled
}

/// The seam between UI and transport. `MockTVController` serves previews and
/// tests; `AndroidTVController` is the real Android TV Remote v2 transport.
@MainActor
public protocol TVController: AnyObject {
    var connectionState: ConnectionState { get }
    var discoveredDevices: [DiscoveredDevice] { get }

    func startDiscovery()
    func stopDiscovery()

    /// Contacts the TV; on return (no throw) the TV is displaying a 6-char
    /// hexadecimal code.
    func beginPairing(with device: DiscoveredDevice) async throws
    /// Submits the code the TV is showing. Throws `.wrongCode` (retryable —
    /// the TV keeps showing its code) or `.pairingFailed`.
    func submitPairingCode(_ code: String) async throws -> PairedDevice
    func cancelPairing()

    func connect(to device: PairedDevice) async throws
    func disconnect()

    /// Fire-and-forget: delivery problems surface via `connectionState`.
    func sendKey(_ key: KeyCommand)
    func sendText(_ text: String)
}
```

Note the old stored `PairedDevice` JSON (no `serviceName`) fails decoding, so
`DeviceStore.pairedDevice` returns nil — mock-era installs simply re-pair.
That is intended; no migration code.

- [ ] **Step 2: Rewrite the mock**

`RemoteCore/Sources/RemoteCore/MockTVController.swift`:

```swift
import Observation

/// Stand-in transport for previews and tests: instant fake discovery, accepts
/// any 6-hex-digit code, records every command.
@MainActor
@Observable
public final class MockTVController: TVController {
    public private(set) var connectionState: ConnectionState = .disconnected
    public private(set) var discoveredDevices: [DiscoveredDevice] = []
    public private(set) var sentKeys: [KeyCommand] = []
    public private(set) var sentText: String = ""
    public private(set) var pairingDevice: DiscoveredDevice?

    private let delay: Duration
    private var discoveryTask: Task<Void, Never>?

    public init(delay: Duration = .milliseconds(300)) {
        self.delay = delay
    }

    public func startDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            discoveredDevices = [
                DiscoveredDevice(name: "Xiaomi TV P1e 32", host: "192.168.31.24", serviceName: "Xiaomi TV P1e 32"),
                DiscoveredDevice(name: "Mi Box S", host: "192.168.31.47", serviceName: "Mi Box S"),
            ]
        }
    }

    public func stopDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = nil
    }

    public func beginPairing(with device: DiscoveredDevice) async throws {
        try? await Task.sleep(for: delay)
        pairingDevice = device
    }

    public func submitPairingCode(_ code: String) async throws -> PairedDevice {
        guard let device = pairingDevice else { throw TVControllerError.cancelled }
        guard code.count == 6, code.allSatisfy(\.isHexDigit) else {
            throw TVControllerError.wrongCode
        }
        connectionState = .connecting
        try? await Task.sleep(for: delay)
        connectionState = .connected
        pairingDevice = nil
        return PairedDevice(name: device.name, host: device.host, serviceName: device.serviceName)
    }

    public func cancelPairing() {
        pairingDevice = nil
    }

    public func connect(to device: PairedDevice) async throws {
        connectionState = .connecting
        try? await Task.sleep(for: delay)
        connectionState = .connected
    }

    public func disconnect() {
        connectionState = .disconnected
    }

    public func sendKey(_ key: KeyCommand) {
        guard connectionState == .connected else { return }
        sentKeys.append(key)
    }

    public func sendText(_ text: String) {
        guard connectionState == .connected else { return }
        sentText = text
    }
}
```

- [ ] **Step 3: Migrate the tests**

Replace the body of `MockTVControllerTests.swift` with:

```swift
import Testing
@testable import RemoteCore

@MainActor
@Test func discoveryPopulatesAfterStart() async throws {
    let controller = MockTVController(delay: .zero)
    controller.startDiscovery()
    try await Task.sleep(for: .milliseconds(50))
    #expect(controller.discoveredDevices.count == 2)
    #expect(controller.discoveredDevices.first?.name == "Xiaomi TV P1e 32")
}

@MainActor
@Test func fullPairingFlowReturnsPairedDevice() async throws {
    let controller = MockTVController(delay: .zero)
    let device = DiscoveredDevice(name: "Xiaomi TV P1e 32", host: "192.168.31.24", serviceName: "Xiaomi TV P1e 32")
    try await controller.beginPairing(with: device)
    let paired = try await controller.submitPairingCode("A1B2C3")
    #expect(paired == PairedDevice(name: "Xiaomi TV P1e 32", host: "192.168.31.24", serviceName: "Xiaomi TV P1e 32"))
    #expect(controller.connectionState == .connected)
}

@MainActor
@Test func nonHexCodeThrowsWrongCode() async throws {
    let controller = MockTVController(delay: .zero)
    let device = DiscoveredDevice(name: "TV", host: "10.0.0.2", serviceName: "TV")
    try await controller.beginPairing(with: device)
    await #expect(throws: TVControllerError.wrongCode) {
        _ = try await controller.submitPairingCode("XYZ!!!")
    }
    #expect(controller.connectionState == .disconnected)
}

@MainActor
@Test func submitWithoutBeginThrowsCancelled() async {
    let controller = MockTVController(delay: .zero)
    await #expect(throws: TVControllerError.cancelled) {
        _ = try await controller.submitPairingCode("A1B2C3")
    }
}

@MainActor
@Test func disconnectResetsState() async throws {
    let controller = MockTVController(delay: .zero)
    try await controller.connect(to: PairedDevice(name: "TV", host: "10.0.0.2", serviceName: "TV"))
    #expect(controller.connectionState == .connected)
    controller.disconnect()
    #expect(controller.connectionState == .disconnected)
}

@MainActor
@Test func keysAndTextAreLoggedOnlyWhileConnected() async throws {
    let controller = MockTVController(delay: .zero)
    controller.sendKey(.up)
    controller.sendText("dropped")
    #expect(controller.sentKeys.isEmpty)
    #expect(controller.sentText.isEmpty)
    try await controller.connect(to: PairedDevice(name: "TV", host: "10.0.0.2", serviceName: "TV"))
    controller.sendKey(.ok)
    controller.sendText("hello")
    #expect(controller.sentKeys == [.ok])
    #expect(controller.sentText == "hello")
}
```

In `PersistenceTests.swift` and `DeviceTypesTests.swift`, update every
`DiscoveredDevice(name:host:)` / `PairedDevice(name:host:)` call to include
`serviceName:` (use the device name as the value). Add one regression test to
`PersistenceTests.swift`:

```swift
@Test func legacyStoredDeviceWithoutServiceNameIsDiscarded() {
    let defaults = freshDefaults()
    defaults.set(Data(#"{"name":"TV","host":"10.0.0.2"}"#.utf8), forKey: "pairedDevice")
    let store = DeviceStore(defaults: defaults)
    #expect(store.pairedDevice == nil)
}
```

- [ ] **Step 4: Run package tests**

Run: `./Scripts/test.sh`
Expected: PASS (old `discover()`/`pair(device:code:)` tests are gone, replaced by the above).

- [ ] **Step 5: Keep the app compiling (minimal shim — NOT the final UX)**

In `App/ConnectView.swift`:
- Replace `.task { devices = await controller.discover() }` with
  `.task { controller.startDiscovery() }` and delete the local
  `@State private var devices` — read `controller.discoveredDevices` in
  `deviceList` instead (rename usages from `devices` to
  `controller.discoveredDevices`).
- Replace the `pair()` function body with the sequential calls:

```swift
    private func pair() {
        guard let device = selected else { return }
        isPairing = true
        Task {
            defer { isPairing = false }
            do {
                try await controller.beginPairing(with: device)
                let paired = try await controller.submitPairingCode(code)
                onPaired(paired)
            } catch {
                code = ""
            }
        }
    }
```

In `App/RemoteControlApp.swift` (`RootView.onAppear`), the stored-device
connect becomes async:

```swift
        .onAppear {
            pairedDevice = store.pairedDevice
        }
        .task {
            if let device = pairedDevice {
                try? await controller.connect(to: device)
            }
        }
```

- [ ] **Step 6: Build the app**

Run (repo root):
```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project RemoteControl.xcodeproj -scheme RemoteControl \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/rc-build build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add -A RemoteCore App
git commit -m "feat: revise TVController seam for real pairing flow"
```

---

### Task 4: KeyCodeMap — keycodes, app links, ASCII text fallback

**Files:**
- Create: `RemoteCore/Sources/RemoteCore/KeyCodeMap.swift`
- Test: `RemoteCore/Tests/RemoteCoreTests/KeyCodeMapTests.swift`

**Interfaces:**
- Consumes: `KeyCommand`, `AppShortcut` (Phase 1); library `Key`.
- Produces (used by Tasks 5, 7):
  - `KeyCodeMap.key(for command: KeyCommand) -> Key?` (nil only for `.launchApp`)
  - `KeyCodeMap.appLink(for app: AppShortcut) -> String`
  - `KeyCodeMap.asciiKeys(for text: String) -> [Key]`

- [ ] **Step 1: Write the failing tests**

`RemoteCore/Tests/RemoteCoreTests/KeyCodeMapTests.swift`:

```swift
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
```

Run: `./Scripts/test.sh --filter KeyCodeMap`
Expected: FAIL — `KeyCodeMap` not defined.

- [ ] **Step 2: Implement**

`RemoteCore/Sources/RemoteCore/KeyCodeMap.swift`:

```swift
@preconcurrency import AndroidTVRemoteControl

/// Pure mapping from the UI's command vocabulary to Android TV keycodes and
/// app deep links. No state, no networking.
enum KeyCodeMap {
    static func key(for command: KeyCommand) -> Key? {
        switch command {
        case .power: .KEYCODE_POWER
        case .up: .KEYCODE_DPAD_UP
        case .down: .KEYCODE_DPAD_DOWN
        case .left: .KEYCODE_DPAD_LEFT
        case .right: .KEYCODE_DPAD_RIGHT
        case .ok: .KEYCODE_DPAD_CENTER
        case .back: .KEYCODE_BACK
        case .home: .KEYCODE_HOME
        case .menu: .KEYCODE_MENU
        case .volumeUp: .KEYCODE_VOLUME_UP
        case .volumeDown: .KEYCODE_VOLUME_DOWN
        case .mute: .KEYCODE_VOLUME_MUTE   // NOT KEYCODE_MUTE (91) — that's mic mute
        case .channelUp: .KEYCODE_CHANNEL_UP
        case .channelDown: .KEYCODE_CHANNEL_DOWN
        case .rewind: .KEYCODE_MEDIA_REWIND
        case .playPause: .KEYCODE_MEDIA_PLAY_PAUSE
        case .fastForward: .KEYCODE_MEDIA_FAST_FORWARD
        case .input: .KEYCODE_TV_INPUT
        case .launchApp: nil
        }
    }

    /// Deep links sent via the library's DeepLink message. Candidate URIs —
    /// verified against the real TV at the dinner checkpoint (Task 12); any
    /// that fail get corrected there.
    static func appLink(for app: AppShortcut) -> String {
        switch app {
        case .netflix: "https://www.netflix.com/title"   // pattern proven in the library's demo
        case .youtube: "https://www.youtube.com"
        case .prime: "https://app.primevideo.com"
        case .miTV: "https://tv.mi.com"                  // best guess — dinner-verified
        }
    }

    /// ASCII-only fallback for text entry: the v2 library has no IME message.
    /// Unsupported characters (including Cyrillic) are skipped by design —
    /// the keyboard task (Task 12) decides the final text strategy.
    static func asciiKeys(for text: String) -> [Key] {
        text.lowercased().compactMap { char in
            switch char {
            case "a"..."z":
                Key(rawValue: UInt(Key.KEYCODE_A.rawValue) + UInt(char.asciiValue! - Character("a").asciiValue!))
            case "0"..."9":
                Key(rawValue: UInt(Key.KEYCODE_0.rawValue) + UInt(char.asciiValue! - Character("0").asciiValue!))
            case " ": .KEYCODE_SPACE
            case ".": .KEYCODE_PERIOD
            case ",": .KEYCODE_COMMA
            default: nil
            }
        }
    }
}
```

- [ ] **Step 3: Run tests — expect pass**

Run: `./Scripts/test.sh --filter KeyCodeMap`
Expected: PASS. (All case names above are verified against the library's `Key.swift` at revision 32393c3.)

- [ ] **Step 4: Commit**

```bash
git add RemoteCore/Sources/RemoteCore/KeyCodeMap.swift RemoteCore/Tests/RemoteCoreTests/KeyCodeMapTests.swift
git commit -m "feat: map KeyCommand vocabulary to Android TV keycodes and app links"
```

---

### Task 5: Session layer — events, state mapping, library-backed sessions

**Files:**
- Create: `RemoteCore/Sources/RemoteCore/Sessions.swift` (protocols + events + pure mapping)
- Create: `RemoteCore/Sources/RemoteCore/LibSessions.swift` (library-backed implementations)
- Test: `RemoteCore/Tests/RemoteCoreTests/SessionMappingTests.swift`

**Interfaces:**
- Consumes: `IdentityProvider` (Task 2), `KeyCodeMap` (Task 4), library types.
- Produces (used by Tasks 7, 8):
  - `enum PairingEvent: Equatable, Sendable { case codeDisplayed, paired, failed(TVControllerError) }`
  - `enum ControlEvent: Equatable, Sendable { case connected, dropped(TVControllerError?) }`
  - `protocol PairingSessioning` / `protocol ControlSessioning` (below, both `@MainActor`)
  - `LibPairingSession(identity:)`, `LibControlSession(identity:)`
  - `func pairingEvent(from:) -> PairingEvent?`, `func controlEvent(from:) -> ControlEvent?`

**Concurrency pattern (Global Constraints):** library callbacks fire on its
internal Network queues. Map to `PairingEvent`/`ControlEvent` *synchronously
inside the callback* (the mapping functions are pure), then hop:
`Task { @MainActor in self.onEvent?(event) }`. Only Sendable events cross.

- [ ] **Step 1: Write the failing mapping tests**

`RemoteCore/Tests/RemoteCoreTests/SessionMappingTests.swift`:

```swift
import Testing
@preconcurrency import AndroidTVRemoteControl
@testable import RemoteCore

@Test func waitingCodeBecomesCodeDisplayed() {
    #expect(pairingEvent(from: .waitingCode) == .codeDisplayed)
}

@Test func successPairedBecomesPaired() {
    #expect(pairingEvent(from: .successPaired) == .paired)
}

@Test func wrongCodeIsItsOwnFailure() {
    #expect(pairingEvent(from: .error(.wrongCode)) == .failed(.wrongCode))
    #expect(pairingEvent(from: .error(.secretNotSuccess)) == .failed(.wrongCode))
}

@Test func otherPairingErrorsCarryDescription() {
    guard case .failed(.pairingFailed(let message))? = pairingEvent(from: .error(.pairingNotSuccess)) else {
        Issue.record("expected pairingFailed"); return
    }
    #expect(!message.isEmpty)
}

@Test func intermediatePairingStatesProduceNoEvent() {
    #expect(pairingEvent(from: .idle) == nil)
    #expect(pairingEvent(from: .connected) == nil)
    #expect(pairingEvent(from: .secretSent) == nil)
}

@Test func remotePairedBecomesConnected() {
    #expect(controlEvent(from: .paired(runningApp: nil)) == .connected)
    #expect(controlEvent(from: .paired(runningApp: "netflix")) == .connected)
}

@Test func remoteErrorBecomesDropped() {
    guard case .dropped(.some(.connectionFailed))? = controlEvent(from: .error(.connectionFailed)) else {
        Issue.record("expected dropped(connectionFailed)"); return
    }
}

@Test func remoteIdleBecomesCleanDrop() {
    #expect(controlEvent(from: .idle) == .dropped(nil))
}

@Test func intermediateRemoteStatesProduceNoEvent() {
    #expect(controlEvent(from: .connected) == nil)   // TCP up ≠ session ready
    #expect(controlEvent(from: .firstConfigSent) == nil)
}
```

Run: `./Scripts/test.sh --filter SessionMapping`
Expected: FAIL — symbols not defined.

- [ ] **Step 2: Implement protocols, events, and mapping**

`RemoteCore/Sources/RemoteCore/Sessions.swift`:

```swift
@preconcurrency import AndroidTVRemoteControl

/// Sendable events — the ONLY values that cross from library queues to the
/// MainActor.
enum PairingEvent: Equatable, Sendable {
    case codeDisplayed
    case paired
    case failed(TVControllerError)
}

enum ControlEvent: Equatable, Sendable {
    case connected
    case dropped(TVControllerError?)   // nil = clean disconnect
}

/// Seams the adapter is tested through; `LibPairingSession`/`LibControlSession`
/// are the production implementations, fakes live in the test target.
@MainActor
protocol PairingSessioning: AnyObject {
    var onEvent: ((PairingEvent) -> Void)? { get set }
    func start(host: String)
    func sendCode(_ code: String)
    func cancel()
}

@MainActor
protocol ControlSessioning: AnyObject {
    var onEvent: ((ControlEvent) -> Void)? { get set }
    func connect(host: String)
    func sendKey(_ key: KeyCommand)
    func sendText(_ text: String)
    func disconnect()
}

/// Pure state→event mapping (unit-tested; returns nil for intermediate states).
func pairingEvent(from state: PairingManager.PairingState) -> PairingEvent? {
    switch state {
    case .waitingCode: .codeDisplayed
    case .successPaired: .paired
    case .error(.wrongCode), .error(.secretNotSuccess): .failed(.wrongCode)
    case .error(let error): .failed(.pairingFailed(String(describing: error)))
    default: nil
    }
}

func controlEvent(from state: RemoteManager.RemoteState) -> ControlEvent? {
    switch state {
    case .paired: .connected
    case .idle: .dropped(nil)
    case .error(let error): .dropped(.connectionFailed(String(describing: error)))
    default: nil
    }
}
```

- [ ] **Step 3: Run mapping tests — expect pass**

Run: `./Scripts/test.sh --filter SessionMapping`
Expected: PASS.

- [ ] **Step 4: Implement the library-backed sessions**

`RemoteCore/Sources/RemoteCore/LibSessions.swift` — the wiring pattern is the
library demo's (`Demo/SwiftUIDemo/RemoteTVManager.swift` in the package
checkout), adapted to our identity and events:

```swift
import Foundation
import Security
@preconcurrency import AndroidTVRemoteControl

/// Builds the TLS/crypto managers the library needs from our bundled identity.
/// The server certificate closure is filled during the TLS handshake via
/// `secTrustClosure` — exactly the demo's wiring.
private func makeManagers(_ identity: IdentityProvider) -> (TLSManager, CryptoManager) {
    let cryptoManager = CryptoManager()
    cryptoManager.clientPublicCertificate = {
        CertManager().getSecKey(identity.publicCertURL)
    }
    let tlsManager = TLSManager {
        CertManager().cert(identity.p12URL, identity.password)
    }
    tlsManager.secTrustClosure = { secTrust in
        cryptoManager.serverPublicCertificate = {
            guard let key = SecTrustCopyKey(secTrust) else {
                return .Error(.secTrustCopyKeyError)
            }
            return .Result(key)
        }
    }
    return (tlsManager, cryptoManager)
}

@MainActor
final class LibPairingSession: PairingSessioning {
    var onEvent: ((PairingEvent) -> Void)?
    private let pairingManager: PairingManager

    init(identity: IdentityProvider) {
        let (tlsManager, cryptoManager) = makeManagers(identity)
        pairingManager = PairingManager(tlsManager, cryptoManager)
        pairingManager.stateChanged = { [weak self] state in
            // Library queue → map synchronously → hop with a Sendable event.
            guard let event = pairingEvent(from: state) else { return }
            Task { @MainActor [weak self] in self?.onEvent?(event) }
        }
    }

    func start(host: String) {
        pairingManager.connect(host, "RemoteControl", "iPhone")
    }

    func sendCode(_ code: String) {
        pairingManager.sendSecret(code)
    }

    func cancel() {
        pairingManager.disconnect()
    }
}

@MainActor
final class LibControlSession: ControlSessioning {
    var onEvent: ((ControlEvent) -> Void)?
    private let remoteManager: RemoteManager

    init(identity: IdentityProvider) {
        let (tlsManager, _) = makeManagers(identity)
        remoteManager = RemoteManager(
            tlsManager,
            CommandNetwork.DeviceInfo("RemoteControl", "iPhone", "1.0.0", "com.example.RemoteControl", "1")
        )
        remoteManager.stateChanged = { [weak self] state in
            guard let event = controlEvent(from: state) else { return }
            Task { @MainActor [weak self] in self?.onEvent?(event) }
        }
    }

    func connect(host: String) {
        remoteManager.connect(host)
    }

    func sendKey(_ key: KeyCommand) {
        if case .launchApp(let app) = key {
            remoteManager.send(DeepLink(KeyCodeMap.appLink(for: app)))
        } else if let keycode = KeyCodeMap.key(for: key) {
            remoteManager.send(KeyPress(keycode))
        }
    }

    func sendText(_ text: String) {
        // ASCII fallback — final text strategy is decided at the dinner
        // checkpoint (Task 12). Unsupported characters are skipped.
        for keycode in KeyCodeMap.asciiKeys(for: text) {
            remoteManager.send(KeyPress(keycode))
        }
    }

    func disconnect() {
        remoteManager.disconnect()
    }
}
```

- [ ] **Step 5: Full test run + build**

Run: `./Scripts/test.sh` (it builds the package as part of testing)
Expected: builds clean (this is where `@preconcurrency` earns its keep — if strict-concurrency *errors* appear, apply the Global Constraints fallback), all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add RemoteCore/Sources/RemoteCore/Sessions.swift RemoteCore/Sources/RemoteCore/LibSessions.swift RemoteCore/Tests/RemoteCoreTests/SessionMappingTests.swift
git commit -m "feat: add session layer wrapping the pairing and control protocol"
```

---

### Task 6: DeviceDiscovery — NWBrowser + endpoint resolution

**Files:**
- Create: `RemoteCore/Sources/RemoteCore/DeviceDiscovery.swift`
- Test: `RemoteCore/Tests/RemoteCoreTests/DeviceDiscoveryTests.swift`

**Interfaces:**
- Consumes: `DiscoveredDevice` (Task 3).
- Produces (used by Tasks 7, 8):
  - `@MainActor @Observable final class DeviceDiscovery` with `devices: [DiscoveredDevice]`, `permissionDenied: Bool`, `start()`, `stop()`, and `static func resolveHost(serviceName: String) async -> String?` (re-resolution for IP changes).
  - Internal pure helper `hostString(from endpoint: NWEndpoint) -> String?` (unit-tested).

- [ ] **Step 1: Write the failing helper tests**

`RemoteCore/Tests/RemoteCoreTests/DeviceDiscoveryTests.swift`:

```swift
import Network
import Testing
@testable import RemoteCore

@Test func ipv4HostPortEndpointYieldsPlainIP() {
    let endpoint = NWEndpoint.hostPort(host: .ipv4(.init("192.168.31.24")!), port: 6466)
    #expect(hostString(from: endpoint) == "192.168.31.24")
}

@Test func ipv6ScopeSuffixIsStripped() {
    let endpoint = NWEndpoint.hostPort(host: .ipv6(.init("fe80::1%en0")!), port: 6466)
    #expect(hostString(from: endpoint) == "fe80::1")
}

@Test func serviceEndpointHasNoHost() {
    let endpoint = NWEndpoint.service(name: "TV", type: "_androidtvremote2._tcp", domain: "local.", interface: nil)
    #expect(hostString(from: endpoint) == nil)
}
```

Run: `./Scripts/test.sh --filter DeviceDiscovery`
Expected: FAIL — `hostString` not defined.

- [ ] **Step 2: Implement**

`RemoteCore/Sources/RemoteCore/DeviceDiscovery.swift`:

```swift
import Foundation
import Network
import Observation

/// Extracts a plain host string from a resolved endpoint (strips IPv6 scope).
func hostString(from endpoint: NWEndpoint) -> String? {
    guard case .hostPort(let host, _) = endpoint else { return nil }
    switch host {
    case .ipv4(let address): return "\(address)"
    case .ipv6(let address): return "\(address)".components(separatedBy: "%").first
    case .name(let name, _): return name
    @unknown default: return nil
    }
}

/// Browses `_androidtvremote2._tcp` and publishes devices as they appear.
/// Each found service is resolved to an IP by opening a short-lived TCP
/// connection to its control port and reading the remote endpoint.
@MainActor
@Observable
public final class DeviceDiscovery {
    public private(set) var devices: [DiscoveredDevice] = []
    public private(set) var permissionDenied = false

    private var browser: NWBrowser?

    public init() {}

    public func start() {
        stop()
        permissionDenied = false
        let browser = NWBrowser(
            for: .bonjour(type: "_androidtvremote2._tcp", domain: nil),
            using: .tcp
        )
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] state in
            // Local-network permission denial surfaces as a DNS policy error.
            if case .waiting(let error) = state, case .dns = error {
                Task { @MainActor [weak self] in self?.permissionDenied = true }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let endpoints: [(name: String, endpoint: NWEndpoint)] = results.compactMap {
                guard case .service(let name, _, _, _) = $0.endpoint else { return nil }
                return (name, $0.endpoint)
            }
            Task { @MainActor [weak self] in
                await self?.resolveAll(endpoints)
            }
        }
        browser.start(queue: .global(qos: .userInitiated))
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    private func resolveAll(_ found: [(name: String, endpoint: NWEndpoint)]) async {
        var resolved: [DiscoveredDevice] = []
        for entry in found {
            if let host = await Self.resolve(endpoint: entry.endpoint) {
                resolved.append(DiscoveredDevice(name: entry.name, host: host, serviceName: entry.name))
            }
        }
        // Keep a stable order for the UI.
        devices = resolved.sorted { $0.name < $1.name }
    }

    /// Re-resolve a known service to its current IP (router reassigned it).
    public static func resolveHost(serviceName: String) async -> String? {
        let endpoint = NWEndpoint.service(
            name: serviceName, type: "_androidtvremote2._tcp", domain: "local.", interface: nil
        )
        return await resolve(endpoint: endpoint)
    }

    private static func resolve(endpoint: NWEndpoint) async -> String? {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(to: endpoint, using: .tcp)
            // Guard against double-resume: state handler can fire repeatedly.
            let resumed = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ value: String?) {
                let first = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                guard first else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let inner = connection.currentPath?.remoteEndpoint {
                        finish(hostString(from: inner))
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { finish(nil) }
        }
    }
}
```

Add `import os` if `OSAllocatedUnfairLock` requires it.

- [ ] **Step 3: Run tests — expect pass**

Run: `./Scripts/test.sh`
Expected: PASS (helper tests; browser/resolver behavior is verified live via rc-probe in Tasks 7/12).

- [ ] **Step 4: Commit**

```bash
git add RemoteCore/Sources/RemoteCore/DeviceDiscovery.swift RemoteCore/Tests/RemoteCoreTests/DeviceDiscoveryTests.swift
git commit -m "feat: add mDNS discovery with endpoint resolution"
```

---

### Task 7: rc-probe — macOS CLI harness

**Files:**
- Modify: `RemoteCore/Package.swift` (executable target)
- Create: `RemoteCore/Sources/rc-probe/main.swift`

**Interfaces:**
- Consumes: `DeviceDiscovery`, `LibPairingSession`, `LibControlSession`, `IdentityProvider`, `KeyCommand`.
- Produces: `swift run rc-probe discover | pair <host> | key <host> <name>` — the dinner debug loop. Uses the session layer (one level above the raw library) so a working probe also validates our wrappers.

- [ ] **Step 1: Add the executable target**

In `RemoteCore/Package.swift` targets array, add:

```swift
        .executableTarget(
            name: "rc-probe",
            dependencies: ["RemoteCore"]
        ),
```

Note: session types and `IdentityProvider.bundled()` resources live in
RemoteCore, so rc-probe needs them visible. Sessions are internal — for the
probe, make `LibPairingSession`, `LibControlSession`, `PairingSessioning`,
`ControlSessioning`, `PairingEvent`, and `ControlEvent` `public` (they are
implementation seams, but the probe is a legitimate second consumer;
initializers become `public init`).

- [ ] **Step 2: Implement the probe**

`RemoteCore/Sources/rc-probe/main.swift`:

```swift
import Foundation
import RemoteCore

// rc-probe — dinner-table debug harness. Drives the same session layer the
// app uses, printing every event.
// Run with the macOS deployment-target flag the dependency forces:
//   F='-Xswiftc -target -Xswiftc '"$(uname -m)"'-apple-macosx14.0'
//   swift run $F rc-probe discover
//   swift run $F rc-probe pair 192.168.31.24
//   swift run $F rc-probe key 192.168.31.24 down

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
                if let code = readLine()?.trimmingCharacters(in: .whitespaces).uppercased() {
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
        print("timed out"); exit(1)

    default:
        print("unknown command \(arguments[1])"); exit(64)
    }
}

await Task { @MainActor in await run() }.value
```

- [ ] **Step 3: Build it (run needs the TV — dinner)**

Run: `cd RemoteCore && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -Xswiftc -target -Xswiftc "$(uname -m)-apple-macosx14.0" --target rc-probe` then `./Scripts/test.sh` from the repo root
Expected: builds clean; all tests still PASS (the `public` widening must not break anything).

- [ ] **Step 4: Commit**

```bash
git add RemoteCore/Package.swift RemoteCore/Sources/rc-probe RemoteCore/Sources/RemoteCore/Sessions.swift RemoteCore/Sources/RemoteCore/LibSessions.swift RemoteCore/Sources/RemoteCore/IdentityProvider.swift
git commit -m "feat: add rc-probe CLI harness for live TV debugging"
```

---

### Task 8: AndroidTVController — the adapter

**Files:**
- Create: `RemoteCore/Sources/RemoteCore/AndroidTVController.swift`
- Test: `RemoteCore/Tests/RemoteCoreTests/AndroidTVControllerTests.swift`

**Interfaces:**
- Consumes: `PairingSessioning`/`ControlSessioning` + events (Task 5), `DeviceDiscovery` (Task 6), `TVController` v2 (Task 3).
- Produces (used by Task 9):
  - `AndroidTVController(identity:makePairing:makeControl:)` implementing `TVController`, `@MainActor @Observable`.
  - Convenience `AndroidTVController(identity:)` using the Lib sessions.

**Policy decisions locked here (from spec, one deliberate deviation):**
- One reconnect attempt when `sendKey` fires while disconnected with a known device.
- On reconnect failure with a stale IP: re-resolve via `DeviceDiscovery.resolveHost(serviceName:)`, retry once, then stay disconnected.
- **Deviation from the spec's lifecycle table:** connection failures never auto-clear `DeviceStore`. The library cannot reliably distinguish "TV rejected our certificate" from "TV is off" (both surface as connection errors), and auto-clearing would un-pair the app every time the TV is powered down. Manual unpair (Settings) remains the recovery path. Record this in the spec during wrap-up.

- [ ] **Step 1: Write the failing tests with fake sessions**

`RemoteCore/Tests/RemoteCoreTests/AndroidTVControllerTests.swift`:

```swift
import Testing
@testable import RemoteCore

@MainActor
final class FakePairingSession: PairingSessioning {
    var onEvent: ((PairingEvent) -> Void)?
    var startedHosts: [String] = []
    var sentCodes: [String] = []
    var cancelled = false
    func start(host: String) { startedHosts.append(host) }
    func sendCode(_ code: String) { sentCodes.append(code) }
    func cancel() { cancelled = true }
    func fire(_ event: PairingEvent) { onEvent?(event) }
}

@MainActor
final class FakeControlSession: ControlSessioning {
    var onEvent: ((ControlEvent) -> Void)?
    var connectedHosts: [String] = []
    var sentKeys: [KeyCommand] = []
    var sentTexts: [String] = []
    var disconnected = false
    func connect(host: String) { connectedHosts.append(host) }
    func sendKey(_ key: KeyCommand) { sentKeys.append(key) }
    func sendText(_ text: String) { sentTexts.append(text) }
    func disconnect() { disconnected = true }
    func fire(_ event: ControlEvent) { onEvent?(event) }
}

@MainActor
private func makeController() -> (AndroidTVController, FakePairingSession, FakeControlSession) {
    let pairing = FakePairingSession()
    let control = FakeControlSession()
    let identity = IdentityProvider.bundled()!
    let controller = AndroidTVController(
        identity: identity,
        makePairing: { pairing },
        makeControl: { control }
    )
    return (controller, pairing, control)
}

private let tv = DiscoveredDevice(name: "TV", host: "192.168.31.24", serviceName: "TV")
private let paired = PairedDevice(name: "TV", host: "192.168.31.24", serviceName: "TV")

@MainActor
@Test func beginPairingResolvesWhenCodeDisplayed() async throws {
    let (controller, pairing, _) = makeController()
    async let begin: Void = controller.beginPairing(with: tv)
    try await Task.sleep(for: .milliseconds(20))     // let beginPairing install its continuation
    pairing.fire(.codeDisplayed)
    try await begin
    #expect(pairing.startedHosts == ["192.168.31.24"])
}

@MainActor
@Test func submitCodeResolvesOnPairedAndReturnsDevice() async throws {
    let (controller, pairing, _) = makeController()
    async let begin: Void = controller.beginPairing(with: tv)
    try await Task.sleep(for: .milliseconds(20))
    pairing.fire(.codeDisplayed)
    try await begin
    async let submit = controller.submitPairingCode("A1B2C3")
    try await Task.sleep(for: .milliseconds(20))
    pairing.fire(.paired)
    let device = try await submit
    #expect(pairing.sentCodes == ["A1B2C3"])
    #expect(device == paired)
}

@MainActor
@Test func wrongCodeThrowsAndAllowsRetry() async throws {
    let (controller, pairing, _) = makeController()
    async let begin: Void = controller.beginPairing(with: tv)
    try await Task.sleep(for: .milliseconds(20))
    pairing.fire(.codeDisplayed)
    try await begin
    async let submit = controller.submitPairingCode("FFFFFF")
    try await Task.sleep(for: .milliseconds(20))
    pairing.fire(.failed(.wrongCode))
    await #expect(throws: TVControllerError.wrongCode) { _ = try await submit }
    // Retry path stays open: a second submit is accepted.
    async let retry = controller.submitPairingCode("A1B2C3")
    try await Task.sleep(for: .milliseconds(20))
    pairing.fire(.paired)
    _ = try await retry
}

@MainActor
@Test func cancelPairingResumesBeginWithCancelled() async throws {
    let (controller, pairing, _) = makeController()
    async let begin: Void = controller.beginPairing(with: tv)
    try await Task.sleep(for: .milliseconds(20))
    controller.cancelPairing()
    await #expect(throws: TVControllerError.cancelled) { try await begin }
    #expect(pairing.cancelled)
}

@MainActor
@Test func connectPublishesStatesAndSendsKeys() async throws {
    let (controller, _, control) = makeController()
    async let connect: Void = controller.connect(to: paired)
    try await Task.sleep(for: .milliseconds(20))
    #expect(controller.connectionState == .connecting)
    control.fire(.connected)
    try await connect
    #expect(controller.connectionState == .connected)
    controller.sendKey(.ok)
    #expect(control.sentKeys == [.ok])
}

@MainActor
@Test func dropMovesToDisconnected() async throws {
    let (controller, _, control) = makeController()
    async let connect: Void = controller.connect(to: paired)
    try await Task.sleep(for: .milliseconds(20))
    control.fire(.connected)
    try await connect
    control.fire(.dropped(nil))
    try await Task.sleep(for: .milliseconds(20))
    #expect(controller.connectionState == .disconnected)
}

@MainActor
@Test func sendKeyWhileDisconnectedTriggersOneReconnect() async throws {
    let (controller, _, control) = makeController()
    async let connect: Void = controller.connect(to: paired)
    try await Task.sleep(for: .milliseconds(20))
    control.fire(.connected)
    try await connect
    control.fire(.dropped(nil))
    try await Task.sleep(for: .milliseconds(20))
    controller.sendKey(.up)                      // swallowed, but kicks reconnect
    try await Task.sleep(for: .milliseconds(20))
    #expect(control.connectedHosts.count == 2)   // initial + reconnect
    controller.sendKey(.down)                    // still connecting: no third attempt
    try await Task.sleep(for: .milliseconds(20))
    #expect(control.connectedHosts.count == 2)
}

@MainActor
@Test func disconnectIsCleanAndFinal() async throws {
    let (controller, _, control) = makeController()
    async let connect: Void = controller.connect(to: paired)
    try await Task.sleep(for: .milliseconds(20))
    control.fire(.connected)
    try await connect
    controller.disconnect()
    #expect(control.disconnected)
    #expect(controller.connectionState == .disconnected)
}
```

Run: `./Scripts/test.sh --filter AndroidTVController`
Expected: FAIL — `AndroidTVController` not defined.

- [ ] **Step 2: Implement the adapter**

`RemoteCore/Sources/RemoteCore/AndroidTVController.swift`:

```swift
import Foundation
import Observation

/// The real transport behind the TVController seam. Owns discovery, a pairing
/// session, and a control session; publishes connectionState for the views.
@MainActor
@Observable
public final class AndroidTVController: TVController {
    public private(set) var connectionState: ConnectionState = .disconnected
    public var discoveredDevices: [DiscoveredDevice] { discovery.devices }
    public var discoveryPermissionDenied: Bool { discovery.permissionDenied }

    private let identity: IdentityProvider
    private let makePairing: () -> any PairingSessioning
    private let makeControl: () -> any ControlSessioning
    private let discovery: DeviceDiscovery

    private var pairingSession: (any PairingSessioning)?
    private var pairingDevice: DiscoveredDevice?
    private var beginContinuation: CheckedContinuation<Void, any Error>?
    private var submitContinuation: CheckedContinuation<Void, any Error>?

    private var controlSession: (any ControlSessioning)?
    private var connectedDevice: PairedDevice?
    private var connectContinuation: CheckedContinuation<Void, any Error>?
    private var reconnectAllowed = true

    public init(
        identity: IdentityProvider,
        discovery: DeviceDiscovery = DeviceDiscovery(),
        makePairing: @escaping () -> any PairingSessioning,
        makeControl: @escaping () -> any ControlSessioning
    ) {
        self.identity = identity
        self.discovery = discovery
        self.makePairing = makePairing
        self.makeControl = makeControl
    }

    /// Production wiring.
    public convenience init(identity: IdentityProvider) {
        self.init(
            identity: identity,
            makePairing: { LibPairingSession(identity: identity) },
            makeControl: { LibControlSession(identity: identity) }
        )
    }

    // MARK: Discovery

    public func startDiscovery() { discovery.start() }
    public func stopDiscovery() { discovery.stop() }

    // MARK: Pairing

    public func beginPairing(with device: DiscoveredDevice) async throws {
        cancelPairing()
        pairingDevice = device
        let session = makePairing()
        pairingSession = session
        session.onEvent = { [weak self] event in self?.handlePairing(event) }
        try await withCheckedThrowingContinuation { continuation in
            beginContinuation = continuation
            session.start(host: device.host)
        }
    }

    public func submitPairingCode(_ code: String) async throws -> PairedDevice {
        guard let session = pairingSession, let device = pairingDevice else {
            throw TVControllerError.cancelled
        }
        try await withCheckedThrowingContinuation { continuation in
            submitContinuation = continuation
            session.sendCode(code)
        }
        pairingSession = nil
        pairingDevice = nil
        return PairedDevice(name: device.name, host: device.host, serviceName: device.serviceName)
    }

    public func cancelPairing() {
        pairingSession?.cancel()
        pairingSession = nil
        pairingDevice = nil
        beginContinuation?.resume(throwing: TVControllerError.cancelled)
        beginContinuation = nil
        submitContinuation?.resume(throwing: TVControllerError.cancelled)
        submitContinuation = nil
    }

    private func handlePairing(_ event: PairingEvent) {
        switch event {
        case .codeDisplayed:
            beginContinuation?.resume()
            beginContinuation = nil
        case .paired:
            submitContinuation?.resume()
            submitContinuation = nil
        case .failed(let error):
            beginContinuation?.resume(throwing: error)
            beginContinuation = nil
            submitContinuation?.resume(throwing: error)
            submitContinuation = nil
        }
    }

    // MARK: Control

    public func connect(to device: PairedDevice) async throws {
        controlSession?.disconnect()
        connectedDevice = device
        connectionState = .connecting
        let session = makeControl()
        controlSession = session
        session.onEvent = { [weak self] event in self?.handleControl(event) }
        do {
            try await withCheckedThrowingContinuation { continuation in
                connectContinuation = continuation
                session.connect(host: device.host)
            }
        } catch {
            connectionState = .disconnected
            throw error
        }
        connectionState = .connected
        reconnectAllowed = true
    }

    public func disconnect() {
        controlSession?.disconnect()
        controlSession = nil
        connectedDevice = nil
        connectionState = .disconnected
    }

    public func sendKey(_ key: KeyCommand) {
        switch connectionState {
        case .connected:
            controlSession?.sendKey(key)
        case .disconnected:
            attemptReconnect()
        case .connecting:
            break
        }
    }

    public func sendText(_ text: String) {
        guard connectionState == .connected else { return }
        controlSession?.sendText(text)
    }

    private func handleControl(_ event: ControlEvent) {
        switch event {
        case .connected:
            connectContinuation?.resume()
            connectContinuation = nil
        case .dropped(let error):
            if let continuation = connectContinuation {
                continuation.resume(throwing: error ?? TVControllerError.connectionFailed("dropped"))
                connectContinuation = nil
            }
            connectionState = .disconnected
        }
    }

    /// One reconnect per drop; a fresh drop re-arms it. On stale-IP failure,
    /// re-resolve the Bonjour service name once.
    private func attemptReconnect() {
        guard reconnectAllowed, let device = connectedDevice else { return }
        reconnectAllowed = false
        Task { [weak self] in
            guard let self else { return }
            do {
                try await connect(to: device)
            } catch {
                if let host = await DeviceDiscovery.resolveHost(serviceName: device.serviceName),
                   host != device.host {
                    let moved = PairedDevice(name: device.name, host: host, serviceName: device.serviceName)
                    try? await connect(to: moved)
                }
            }
        }
    }
}
```

- [ ] **Step 3: Run the tests — expect pass**

Run: `./Scripts/test.sh`
Expected: all PASS. Watch `sendKeyWhileDisconnectedTriggersOneReconnect` — it pins the "exactly one attempt while disconnected" policy.

- [ ] **Step 4: Commit**

```bash
git add RemoteCore/Sources/RemoteCore/AndroidTVController.swift RemoteCore/Tests/RemoteCoreTests/AndroidTVControllerTests.swift
git commit -m "feat: add AndroidTVController adapter with reconnect policy"
```

---

### Task 9: App wiring — Info.plist keys, real controller, scenePhase

**Files:**
- Modify: `project.yml`, `.gitignore`
- Modify: `App/RemoteControlApp.swift`

**Interfaces:**
- Consumes: `AndroidTVController(identity:)` (Task 8), `IdentityProvider.bundled()` (Task 2).
- Produces: the app runs against the real transport; `RootView` handles scenePhase.

- [ ] **Step 1: Move project.yml to an explicit info block**

In `project.yml`, inside the `RemoteControl` target: add the `info:` block and
**delete** `GENERATE_INFOPLIST_FILE` and both `INFOPLIST_KEY_*` lines from
settings (they move into `info.properties`):

```yaml
    info:
      path: App/Info.plist
      properties:
        NSLocalNetworkUsageDescription: RemoteControl discovers and controls Android TVs on your Wi-Fi network.
        NSBonjourServices: [_androidtvremote2._tcp]
        UILaunchScreen: {}
        UISupportedInterfaceOrientations: [UIInterfaceOrientationPortrait]
```

Append `App/Info.plist` to `.gitignore` (xcodegen regenerates it).

- [ ] **Step 2: Swap in the real controller + scenePhase policy**

`App/RemoteControlApp.swift` becomes:

```swift
import RemoteCore
import SwiftUI

@main
struct RemoteControlApp: App {
    @State private var controller = AndroidTVController(identity: IdentityProvider.bundled()!)
    private let store = DeviceStore()

    var body: some Scene {
        WindowGroup {
            RootView(controller: controller, store: store)
        }
    }
}

struct RootView: View {
    let controller: AndroidTVController
    let store: DeviceStore
    @State private var pairedDevice: PairedDevice?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if let device = pairedDevice {
                RemoteView(controller: controller, device: device) {
                    controller.disconnect()
                    store.clear()
                    pairedDevice = nil
                }
            } else {
                ConnectView(controller: controller) { device in
                    store.save(device)
                    pairedDevice = device
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { pairedDevice = store.pairedDevice }
        .onChange(of: scenePhase) { _, phase in
            // iOS kills LAN sockets in background: disconnect cleanly, then
            // reconnect on return.
            switch phase {
            case .background:
                controller.disconnect()
            case .active:
                if let device = pairedDevice, controller.connectionState == .disconnected {
                    Task { try? await controller.connect(to: device) }
                }
            default:
                break
            }
        }
        .task {
            if let device = pairedDevice {
                try? await controller.connect(to: device)
            }
        }
    }
}
```

Note `onUnpair` now calls `controller.disconnect()` before clearing — the
`disconnect()` gap from phase2-notes is closed here.

- [ ] **Step 3: Regenerate, build, verify the plist**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
plutil -p App/Info.plist | grep -A2 Bonjour   # must show _androidtvremote2._tcp
xcodebuild -project RemoteControl.xcodeproj -scheme RemoteControl \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/rc-build build
```
Expected: plist contains both privacy keys; BUILD SUCCEEDED.

- [ ] **Step 4: Simulator smoke test**

Install + launch per HANDOFF "How to run". Expected: app boots to Connect
screen; discovery spins (no TVs on the Mac's network is fine — no crash, and
the local-network permission prompt appears in the simulator).

- [ ] **Step 5: Commit**

```bash
git add project.yml .gitignore App/RemoteControlApp.swift
git commit -m "feat: wire the real Android TV controller into the app"
```

---

### Task 10: ConnectView — real pairing flow, hex code, permission UX

**Files:**
- Modify: `App/ConnectView.swift`

**Interfaces:**
- Consumes: `TVController` v2 (Task 3), `AndroidTVController.discoveryPermissionDenied` (Task 8).
- Produces: the final Connect UX. Visual design stays locked — same cards, colors, and type; only flow and copy change.

**Flow states** (one `enum Phase` in the view): `browsing` → tap device →
`requesting` ("Look at your TV…") → `codeEntry` (TV is showing the code) →
submit → `submitting` → success (`onPaired`) or inline error back to `codeEntry`.

- [ ] **Step 1: Rewrite the view**

Replace `App/ConnectView.swift` body logic (keeping the existing visual
building blocks — header text, `deviceList` card, code boxes, Pair button):

```swift
import RemoteCore
import SwiftUI

struct ConnectView: View {
    let controller: any TVController
    var onPaired: (PairedDevice) -> Void

    private enum Phase: Equatable {
        case browsing, requesting, codeEntry, submitting
    }

    @State private var phase: Phase = .browsing
    @State private var selected: DiscoveredDevice?
    @State private var code = ""
    @State private var errorText: String?
    @FocusState private var codeFocused: Bool

    private var permissionDenied: Bool {
        (controller as? AndroidTVController)?.discoveryPermissionDenied ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Connect your TV")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Your iPhone and TV need to be on the same Wi-Fi network.")
                        .font(.system(size: 15))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 8)

                    if permissionDenied {
                        permissionCard.padding(.top, 28)
                    } else {
                        searchStatus.padding(.top, 28)
                        sectionHeader.padding(.top, 24)
                        deviceList.padding(.top, 8)
                        if phase == .requesting {
                            lookAtTVCard.padding(.top, 24)
                        }
                        if phase == .codeEntry || phase == .submitting {
                            pairingCard.padding(.top, 24)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)

            if phase == .codeEntry || phase == .submitting {
                pairButton.padding(.top, 12)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(Theme.background.ignoresSafeArea())
        .task { controller.startDiscovery() }
        .onDisappear {
            controller.stopDiscovery()
            controller.cancelPairing()
        }
    }

    // MARK: Actions

    private func select(_ device: DiscoveredDevice) {
        guard phase == .browsing || phase == .codeEntry else { return }
        selected = device
        errorText = nil
        code = ""
        phase = .requesting
        Task {
            do {
                try await controller.beginPairing(with: device)
                phase = .codeEntry
                codeFocused = true
            } catch {
                phase = .browsing
                selected = nil
                errorText = "Couldn't reach the TV. Make sure it's on and try again."
            }
        }
    }

    private func submit() {
        guard code.count == 6 else { return }
        phase = .submitting
        errorText = nil
        Task {
            do {
                let device = try await controller.submitPairingCode(code)
                onPaired(device)
            } catch TVControllerError.wrongCode {
                phase = .codeEntry
                code = ""
                codeFocused = true
                errorText = "That code didn't match. Check the TV and try again."
            } catch {
                phase = .browsing
                selected = nil
                code = ""
                errorText = "Pairing failed. Select your TV to try again."
            }
        }
    }

    // MARK: Subviews

    private var searchStatus: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi").font(.system(size: 14))
            Text(controller.discoveredDevices.isEmpty ? "Searching on your Wi-Fi…" : "Found on your Wi-Fi")
                .font(.system(size: 13))
        }
        .foregroundStyle(Theme.textSecondary)
    }

    private var sectionHeader: some View {
        Text("ON YOUR NETWORK")
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.textTertiary)
            .padding(.leading, 4)
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Local network access is off")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("RemoteControl needs local network access to find your TV. Enable it in Settings.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Open Settings")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private var lookAtTVCard: some View {
        HStack(spacing: 12) {
            ProgressView().tint(Theme.accent)
            Text("Look at your TV — asking it to show a pairing code…")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private var deviceList: some View {
        VStack(spacing: 0) {
            ForEach(Array(controller.discoveredDevices.enumerated()), id: \.element.id) { index, device in
                if index > 0 {
                    Rectangle()
                        .fill(Theme.hairline)
                        .frame(height: 1)
                        .padding(.leading, 66)
                }
                Button {
                    select(device)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "tv")
                            .font(.system(size: 16))
                            .foregroundStyle(selected?.id == device.id ? Theme.accent : Theme.textTertiary)
                            .frame(width: 38, height: 38)
                            .background(Theme.controlHigh, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(device.host)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: selected?.id == device.id ? "checkmark" : "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(selected?.id == device.id ? Theme.accent : Theme.chevron)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 64)
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Pair with \(device.name)")
            }
            if controller.discoveredDevices.isEmpty {
                HStack {
                    ProgressView().tint(Theme.textSecondary)
                    Spacer()
                }
                .padding(16)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Enter the pairing code")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Your TV is showing a 6-character code")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
            if let errorText {
                Text(errorText)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 4)
            }

            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { index in
                    let digits = Array(code)
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Theme.controlHigh)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(index == code.count ? Theme.accent : .clear, lineWidth: 1.5)
                        )
                        .overlay(
                            Text(index < digits.count ? String(digits[index]) : "")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                        )
                        .frame(height: 54)
                }
            }
            .padding(.top, 14)
            .background(
                TextField("", text: $code)
                    .keyboardType(.asciiCapable)          // hex codes: letters happen
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($codeFocused)
                    .disabled(phase == .submitting)
                    .opacity(0.01)
                    .accessibilityLabel("Pairing code")
            )
            .onTapGesture { codeFocused = true }
            .onChange(of: code) { _, newValue in
                code = String(newValue.uppercased().filter(\.isHexDigit).prefix(6))
            }
        }
        .padding(18)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private var pairButton: some View {
        Button(action: submit) {
            Text(phase == .submitting ? "Pairing…" : "Pair")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.background)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(
                    Theme.accent.opacity(code.count == 6 && phase == .codeEntry ? 1 : 0.35),
                    in: RoundedRectangle(cornerRadius: 14)
                )
        }
        .buttonStyle(PressableStyle())
        .disabled(code.count != 6 || phase != .codeEntry)
    }
}
```

Add `Theme.chevron` (the previously inline `Color(hex: 0x5C5C66)`) to
`App/Theme.swift` as part of this task:

```swift
    static let chevron = Color(hex: 0x5C5C66)
```

- [ ] **Step 2: Build + simulator check against the mock-free app**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project RemoteControl.xcodeproj -scheme RemoteControl \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/rc-build build
```
Expected: BUILD SUCCEEDED. Install + launch: Connect screen shows "Searching
on your Wi-Fi…" without crashing (no TV on the dev network yet — the pairing
tap-through itself is dinner verification).

- [ ] **Step 3: Commit**

```bash
git add App/ConnectView.swift App/Theme.swift
git commit -m "feat: real pairing flow in Connect with hex codes and permission UX"
```

---

### Task 11: Settings, accessibility, theme consolidation

**Files:**
- Modify: `App/SettingsView.swift`, `App/RemoteView.swift`, `App/KeyboardSheet.swift`, `App/Components.swift`, `App/Theme.swift`

**Interfaces:**
- Consumes: `connectionState` (already published).
- Produces: the remaining phase2-notes absorptions.

- [ ] **Step 1: Live badge in Settings**

`SettingsView` gains the controller and drives the badge:

- Add property: `let controller: any TVController` (update the
  `SettingsView(device:onUnpair:)` call in `RemoteView.swift` to pass its
  `controller`).
- Replace the hardcoded `Text("Connected")` with:

```swift
    Text(controller.connectionState == .connected ? "Connected" : "Not connected")
        .foregroundStyle(controller.connectionState == .connected ? Theme.accent : Theme.textTertiary)
```
(match the existing font/modifiers already on that Text).

- [ ] **Step 2: Accessibility labels**

Add `.accessibilityLabel(...)` to every icon-only control:
- `RemoteView.swift`: input button ("Input source"), mic button ("Voice search"),
  keyboard tile ("Keyboard"), settings gear ("Settings"), power ("Power"),
  mode segments ("D-pad mode" / "Touchpad mode").
- `KeyboardSheet.swift`: the TextField ("Text to send to TV").
- `Components.swift`: if `DPadView`/rocker buttons render icon-only, label each
  ("Up", "Down", "Left", "Right", "OK", "Volume up", "Volume down",
  "Channel up", "Channel down", "Mute", "Back", "Home", "Rewind",
  "Play pause", "Fast forward").

- [ ] **Step 3: Theme consolidation**

Move remaining literal colors into `Theme.swift` and reference them:
- `KeyboardSheet.swift`: `0x111218` → `Theme.sheetBackground`, `0x7C7C86` → `Theme.sheetPlaceholder`
- `SettingsView.swift`: `0xA9A9B2` → `Theme.iconMuted`

```swift
    static let sheetBackground = Color(hex: 0x111218)
    static let sheetPlaceholder = Color(hex: 0x7C7C86)
    static let iconMuted = Color(hex: 0xA9A9B2)
```

- [ ] **Step 4: Build + package tests**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project RemoteControl.xcodeproj -scheme RemoteControl \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/rc-build build
./Scripts/test.sh
```
Expected: BUILD SUCCEEDED; tests PASS.

- [ ] **Step 5: Commit**

```bash
git add App
git commit -m "feat: live connection badge, accessibility labels, theme consolidation"
```

---

### Task 12: Dinner verification protocol (manual, with the TV)

**Files:**
- Create: `docs/phase2-dinner-checklist.md`

This task has two parts: writing the checklist doc (before dinner, committed),
and executing it (at dinner, human + agent together). Execution outcomes feed
the wrap-up: fixed URIs, the keyboard decision, and any library bugs found.

- [ ] **Step 1: Write the checklist**

`docs/phase2-dinner-checklist.md`:

```markdown
# Phase 2 dinner checklist — real TV verification

Prereqs: Mac + iPhone/simulator host and the Xiaomi TV P1e 32 on the same
Wi-Fi; TV fully on (not standby) for first pairing.

## A. Probe first (Mac, fastest loop)
1. `cd RemoteCore && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run -Xswiftc -target -Xswiftc "$(uname -m)-apple-macosx14.0" rc-probe discover`
   — expect the TV listed with an IP. macOS may show a local-network
   permission prompt: accept.
2. `swift run … rc-probe pair <ip>` (same flags) — expect the TV to display a 6-char code;
   type it; expect ✅ PAIRED.
3. `swift run … rc-probe key <ip> down` (same flags) — expect focus to move on the TV.
   If A fails, debug HERE (add a `DefaultLogger()` to the session managers in
   LibSessions.swift for full protocol traces) before touching the app.

## B. App on the simulator (same Wi-Fi as the TV)
4. Fresh install → local-network prompt appears → accept → TV appears in list.
5. Tap TV → "Look at your TV…" → code shows ON the TV → enter → Remote screen.
6. Relaunch app → connects silently (header dot orange, "Connected").
7. D-pad up/down/left/right/OK move focus. Back, Home work.
8. Volume up/down/mute work. Power toggles standby; power again wakes it.
9. Background the app (Home), reopen → reconnects.
10. Settings shows live "Connected"; Unpair → returns to Connect; re-pair works.
11. Wrong-code path: pair, type a wrong code → inline error, retry succeeds.

## C. App tiles (fix URIs as found)
12. Tap NETFLIX / YOUTUBE / PRIME / MI TV tiles. For each that fails to open
    the right app, adjust `KeyCodeMap.appLink(for:)` and retest. If no working
    link is found for MI TV, remove that tile's action mapping and note it for
    Phase 3.

## D. Keyboard decision (spec risk #2)
13. Open a search box on the TV, open the app's keyboard sheet, send "test 123".
    - Works via ASCII keys → keep, document ASCII-only (no Cyrillic).
    - Flaky/broken → decide: implement the protocol's text message via the
      library's public `send(RequestDataProtocol)` extension point, or ship
      the sheet disabled and move text entry to Phase 3.

## E. Robustness
14. Turn the TV off at the mains for 1 min, back on, wait for boot → app
    reconnects (possibly after one keypress).
15. If reachable: change the TV's IP (router DHCP reservation) → app recovers
    via mDNS re-resolution after one keypress.

Record every deviation in docs/phase2-notes.md.
```

- [ ] **Step 2: Commit**

```bash
git add docs/phase2-dinner-checklist.md
git commit -m "docs: add dinner verification checklist for Phase 2"
```

- [ ] **Step 3 (at dinner): execute A–E, fix what fails, commit fixes**

Small fixes (URIs, copy, timeouts) go directly on main with focused commits.
Anything structural (library bug needing a fork, keyboard strategy change)
gets raised before coding.

---

## Final verification (after Task 12)

- [ ] `./Scripts/test.sh` — all green.
- [ ] Full simulator build + install + launch — Connect or Remote screen per pairing state.
- [ ] `docs/phase2-notes.md` updated: absorbed items removed, dinner findings recorded.
- [ ] Spec updated with the Task 8 deviation (no auto-clear of DeviceStore) and any dinner-forced changes.
- [ ] Handoff wrap-up (`/handoff`).

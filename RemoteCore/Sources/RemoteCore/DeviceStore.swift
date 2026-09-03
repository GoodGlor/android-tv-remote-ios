import Foundation

/// Persists the single paired TV in UserDefaults.
public struct DeviceStore {
    private static let key = "pairedDevice"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var pairedDevice: PairedDevice? {
        defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(PairedDevice.self, from: $0) }
    }

    public func save(_ device: PairedDevice) {
        defaults.set(try? JSONEncoder().encode(device), forKey: Self.key)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}

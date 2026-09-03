import Foundation
import Testing
@testable import RemoteCore

@Test func pairedDeviceRoundTripsThroughJSON() throws {
    let device = PairedDevice(name: "Xiaomi TV P1e 32", host: "192.168.31.24", serviceName: "Xiaomi TV P1e 32")
    let data = try JSONEncoder().encode(device)
    let decoded = try JSONDecoder().decode(PairedDevice.self, from: data)
    #expect(decoded == device)
}

@Test func discoveredDeviceIdentityIsItsHost() {
    let device = DiscoveredDevice(name: "Mi Box S", host: "192.168.31.47", serviceName: "Mi Box S")
    #expect(device.id == "192.168.31.47")
}

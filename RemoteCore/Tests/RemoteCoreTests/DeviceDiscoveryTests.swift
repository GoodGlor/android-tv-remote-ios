import Network
import Testing
@testable import RemoteCore

@Test func ipv4HostPortEndpointYieldsPlainIP() {
    let endpoint = NWEndpoint.hostPort(host: .ipv4(.init("192.168.31.24")!), port: 6466)
    #expect(hostString(from: endpoint) == "192.168.31.24")
}

// Regression: resolving against a real TV returned "192.168.0.103%en0".
// The scope leaked into PairedDevice.host and made the address unusable.
@Test func ipv4ScopeSuffixIsStripped() {
    let endpoint = NWEndpoint.hostPort(host: .ipv4(.init("192.168.0.103%en0")!), port: 6466)
    #expect(hostString(from: endpoint) == "192.168.0.103")
}

// A link-local IPv6 address is unroutable without its scope, so it keeps it.
@Test func ipv6LinkLocalKeepsItsScope() {
    let endpoint = NWEndpoint.hostPort(host: .ipv6(.init("fe80::1%en0")!), port: 6466)
    #expect(hostString(from: endpoint) == "fe80::1%en0")
}

@Test func routableIPv6ScopeSuffixIsStripped() {
    let endpoint = NWEndpoint.hostPort(host: .ipv6(.init("2001:db8::1%en0")!), port: 6466)
    #expect(hostString(from: endpoint) == "2001:db8::1")
}

@Test func serviceEndpointHasNoHost() {
    let endpoint = NWEndpoint.service(name: "TV", type: "_androidtvremote2._tcp", domain: "local.", interface: nil)
    #expect(hostString(from: endpoint) == nil)
}

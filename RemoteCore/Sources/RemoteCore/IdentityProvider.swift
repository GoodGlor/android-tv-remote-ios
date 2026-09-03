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

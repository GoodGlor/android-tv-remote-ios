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

import Foundation
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
    #expect(pairingEvent(from: .error(.secretNotSuccess(Data()))) == .failed(.wrongCode))
}

@Test func otherPairingErrorsCarryDescription() {
    guard case .failed(.pairingFailed(let message))? = pairingEvent(from: .error(.pairingNotSuccess(Data()))) else {
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
    guard case .dropped(.some(.connectionFailed))? = controlEvent(from: .error(.connectionFailed(AndroidTVRemoteControlError.wrongCode))) else {
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

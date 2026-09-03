import Testing
@testable import RemoteCore

@Test func appShortcutsHaveDistinctNonEmptyLabels() {
    let labels = AppShortcut.allCases.map(\.label)
    #expect(labels.allSatisfy { !$0.isEmpty })
    #expect(Set(labels).count == AppShortcut.allCases.count)
    #expect(AppShortcut.browser.label == "BROWSER")
}

@Test func launchAppCommandsAreDistinctPerShortcut() {
    let commands = Set(AppShortcut.allCases.map { KeyCommand.launchApp($0) })
    #expect(commands.count == AppShortcut.allCases.count)
    #expect(!commands.contains(.ok))
}

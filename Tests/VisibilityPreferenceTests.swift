import Foundation

enum VisibilityPreferenceTests {
    @MainActor static func run() throws {
        let domain = "tr.tunneldesk.visibility-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = VisibilityPreferences(defaults: defaults)
        try IntegrationTests.expect(!settings.showDock && settings.showMenuBar, "Visibility defaults to hidden Dock and visible menu bar")
        var publications = 0
        let observation = settings.objectWillChange.sink { publications += 1 }
        settings.setShowDock(settings.showDock); settings.setShowMenuBar(settings.showMenuBar)
        try IntegrationTests.expect(publications == 0, "Repeated menu insertion bindings cannot trigger recursive scene updates")
        observation.cancel()
        var applied: [Bool] = []
        settings.connectToApplication { applied.append($0); return true }
        settings.setShowDock(true)
        try IntegrationTests.expect(settings.showDock && applied.last == true, "Dock changes apply immediately through the activation-policy callback")
        settings.setShowMenuBar(false)
        let restored = VisibilityPreferences(defaults: defaults)
        try IntegrationTests.expect(restored.showDock && !restored.showMenuBar, "Dock and tray settings survive relaunch")
        settings.setShowDock(false)
        try IntegrationTests.expect(!settings.showDock && settings.showMenuBar, "Hiding the final Dock icon first restores the menu-bar icon")
        settings.setShowMenuBar(false)
        try IntegrationTests.expect(settings.showDock && !settings.showMenuBar, "Hiding the final menu-bar icon first restores the Dock icon")
        defaults.set(false, forKey: "appearance.showDock")
        defaults.set(false, forKey: "appearance.showMenuBar")
        let repaired = VisibilityPreferences(defaults: defaults)
        try IntegrationTests.expect(!repaired.showDock && repaired.showMenuBar, "Invalid persisted all-hidden settings are repaired at startup")
        repaired.connectToApplication { !$0 }
        repaired.setShowMenuBar(false)
        try IntegrationTests.expect(!repaired.showDock && repaired.showMenuBar && repaired.error != nil, "Failed Dock activation cannot remove the last accessible icon")
    }
}

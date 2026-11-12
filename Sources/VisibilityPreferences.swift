import Foundation
import Combine

@MainActor
final class VisibilityPreferences: ObservableObject {
    @Published private(set) var showDock: Bool
    @Published private(set) var showMenuBar: Bool
    @Published private(set) var error: String?
    private let defaults: UserDefaults
    private var applyDockPolicy: ((Bool) -> Bool)?
    private static let dockKey = "appearance.showDock"
    private static let menuKey = "appearance.showMenuBar"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Self.dockKey: false, Self.menuKey: true])
        showDock = defaults.bool(forKey: Self.dockKey)
        showMenuBar = defaults.bool(forKey: Self.menuKey)
        if !showDock && !showMenuBar {
            showMenuBar = true
            defaults.set(true, forKey: Self.menuKey)
        }
    }
    func connectToApplication(_ apply: @escaping (Bool) -> Bool) {
        applyDockPolicy = apply
        if !apply(showDock) {
            showDock = false; showMenuBar = true
            persist()
            error = "Dock görünürlüğü değiştirilemedi. Menü çubuğu simgesi açık tutuldu."
        }
    }
    func setShowDock(_ enabled: Bool) {
        guard enabled != showDock else { return }
        if !enabled && !showMenuBar { setShowMenuBar(true) }
        guard applyDockPolicy?(enabled) ?? true else {
            error = "Dock görünürlüğü değiştirilemedi. Tekrar deneyebilirsin."
            return
        }
        showDock = enabled; error = nil; persist()
    }
    func setShowMenuBar(_ enabled: Bool) {
        guard enabled != showMenuBar else { return }
        if !enabled && !showDock {
            setShowDock(true)
            guard showDock else { return }
        }
        showMenuBar = enabled; error = nil; persist()
    }
    private func persist() {
        defaults.set(showDock, forKey: Self.dockKey)
        defaults.set(showMenuBar, forKey: Self.menuKey)
    }
}

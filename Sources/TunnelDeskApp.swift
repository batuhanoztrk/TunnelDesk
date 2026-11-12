import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var engine: TunnelEngine?
    weak var visibility: VisibilityPreferences?
    private var terminating = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating, let engine else { return terminating ? .terminateLater : .terminateNow }
        terminating = true
        Task { @MainActor in
            await engine.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        visibility?.connectToApplication { showDock in
            let policy: NSApplication.ActivationPolicy = showDock ? .regular : .accessory
            if NSApp.activationPolicy() == policy { return true }
            let applied = NSApp.setActivationPolicy(policy)
            if applied && NSApp.windows.contains(where: \.isVisible) { NSApp.activate(ignoringOtherApps: true) }
            return applied
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct TunnelDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var engine: TunnelEngine
    @StateObject private var updater: AppUpdater
    @StateObject private var visibility: VisibilityPreferences
    @StateObject private var startup = StartupPreferences()
    init() {
        let engine = TunnelEngine()
        let visibility = VisibilityPreferences()
        _engine = StateObject(wrappedValue: engine)
        _updater = StateObject(wrappedValue: AppUpdater(engine: engine))
        _visibility = StateObject(wrappedValue: visibility)
        delegate.engine = engine
        delegate.visibility = visibility
    }
    var body: some Scene {
        WindowGroup("TunnelDesk", id: "main") {
            MainView().environmentObject(engine).onAppear { updater.start() }
        }.defaultSize(width: 1120, height: 760)
            .commands {
                CommandGroup(replacing: .newItem) {}
                CommandGroup(after: .appInfo) {
                    Button("Güncellemeleri kontrol et…") { updater.check() }.disabled(!updater.canCheck)
                    Divider()
                }
                CommandMenu("Tüneller") {
                    Button("Tümünü aç") { engine.startAll() }.keyboardShortcut("o", modifiers: [.command, .shift])
                    Button("Tümünü kapat") { engine.stopAll() }.keyboardShortcut("k", modifiers: [.command, .shift])
                    Divider()
                    Button("Kayıt dosyasını Finder'da göster") { NSWorkspace.shared.activateFileViewerSelecting([engine.store.url]) }
                }
            }
        MenuBarExtra(isInserted: Binding(get: { visibility.showMenuBar }, set: visibility.setShowMenuBar)) {
            TrayMenu(engine: engine, updater: updater)
        } label: {
            Image(systemName: "point.3.connected.trianglepath.dotted").accessibilityLabel("TunnelDesk")
            if engine.runningCount > 0 { Text("\(engine.runningCount)") }
        }.menuBarExtraStyle(.menu)
        Settings {
            TabView {
                AppearanceSettingsView(visibility: visibility, startup: startup).tabItem { Label("Genel", systemImage: "slider.horizontal.3") }
                UpdateSettingsView(updater: updater).tabItem { Label("Güncellemeler", systemImage: "arrow.triangle.2.circlepath") }
            }.frame(width: 510, height: 460)
        }
    }
}

struct TrayMenu: View {
    @ObservedObject var engine: TunnelEngine
    @ObservedObject var updater: AppUpdater
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Button("TunnelDesk'i aç") {
            if let window = NSApp.windows.first(where: { $0.title == "TunnelDesk" && !($0 is NSPanel) }) {
                window.deminiaturize(nil); window.makeKeyAndOrderFront(nil)
            } else { openWindow(id: "main") }
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        if engine.profiles.isEmpty { Text("Henüz tünel eklenmedi") }
        ForEach(engine.profiles) { profile in
            let state = engine.session(for: profile.id)
            Button {
                if state.status.busy { engine.stop(profile) } else { engine.start(profile) }
            } label: { Text("\(state.status == .running ? "●" : "○")  \(profile.name) · \(state.status.title)") }.disabled(state.status == .stopping)
        }
        Divider()
        Button("Tümünü aç") { engine.startAll() }.disabled(engine.profiles.isEmpty)
        Button("Tümünü kapat") { engine.stopAll() }.disabled(engine.activeCount == 0)
        Divider()
        Button("Güncellemeleri kontrol et…") { updater.check() }.disabled(!updater.canCheck)
        Button("Ayarlar…") { NSApp.activate(ignoringOtherApps: true); openSettings() }.keyboardShortcut(",")
        Divider()
        Button("Çıkış") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

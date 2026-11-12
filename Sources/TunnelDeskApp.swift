import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var engine: TunnelEngine?
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
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct TunnelDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var engine: TunnelEngine
    @StateObject private var updater: AppUpdater
    init() {
        let engine = TunnelEngine()
        _engine = StateObject(wrappedValue: engine)
        _updater = StateObject(wrappedValue: AppUpdater(engine: engine))
    }
    var body: some Scene {
        WindowGroup("TunnelDesk", id: "main") {
            MainView().environmentObject(engine).onAppear { delegate.engine = engine; updater.start() }
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
        MenuBarExtra {
            TrayMenu(engine: engine, updater: updater)
        } label: {
            Image(systemName: "point.3.connected.trianglepath.dotted")
            if engine.runningCount > 0 { Text("\(engine.runningCount)") }
        }
        Settings { UpdateSettingsView(updater: updater) }
    }
}

struct TrayMenu: View {
    @ObservedObject var engine: TunnelEngine
    @ObservedObject var updater: AppUpdater
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("TunnelDesk'i aç") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
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
        Divider()
        Button("Çıkış") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

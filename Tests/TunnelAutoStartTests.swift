import Foundation

enum TunnelAutoStartTests {
    @MainActor static func run(fake: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TunnelDesk-autostart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config.yaml"); try Data("test-only".utf8).write(to: config)
        let tools = ToolPaths(kubectl: fake, ssh: fake)
        func profile(_ name: String, auto: Bool, namespace: String = "test", file: URL? = nil) throws -> TunnelProfile {
            var p = TunnelProfile(); p.name = name; p.kind = .kubernetes
            p.kubeconfig = (file ?? config).path; p.context = "test-context"; p.namespace = namespace
            p.resource = "pod/test"; p.remotePort = "1433"; p.localPort = try IntegrationTests.availablePort(); p.autoStartOnLaunch = auto
            return p
        }
        let a = try profile("automatic", auto: true), b = try profile("manual", auto: false)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as! [String: Any]
        legacy.removeValue(forKey: "autoStartOnLaunch")
        let decoded = try JSONDecoder().decode(TunnelProfile.self, from: JSONSerialization.data(withJSONObject: legacy))
        try IntegrationTests.expect(!TunnelProfile().autoStartOnLaunch && !decoded.autoStartOnLaunch && decoded.id == a.id && decoded.context == a.context, "Old and new profiles default to manual startup without losing existing fields")
        let store = ProfileStore(url: root.appendingPathComponent("main/profiles.json")); try store.save([a, b])
        let engine = TunnelEngine(store: store, tools: tools)
        try IntegrationTests.expect(engine.importingConfigs, "Automatic tunnel launch initially waits for legacy kubeconfig import")
        engine.startConfiguredTunnelsOnLaunch()
        try await IntegrationTests.wait("Only opted-in tunnel opens after config import completes") { engine.runningCount == 1 && engine.session(for: a.id).status == .running }
        try IntegrationTests.expect(!engine.importingConfigs && engine.session(for: b.id).status == .stopped, "Opted-out tunnel remains closed and startup uses imported config")
        let generation = engine.session(for: a.id).generation
        try engine.setAutoStartOnLaunch(for: a.id, enabled: false)
        try IntegrationTests.expect(engine.session(for: a.id).status == .running && engine.session(for: a.id).generation == generation, "Auto-start setting can change while running without reconnecting the tunnel")
        try engine.setAutoStartOnLaunch(for: b.id, enabled: true)
        try IntegrationTests.expect(engine.session(for: b.id).status == .stopped, "Enabling auto-start takes effect next launch and does not start a tunnel immediately")
        let saved = try store.load()
        try IntegrationTests.expect(saved.first(where: { $0.id == a.id })?.autoStartOnLaunch == false && saved.first(where: { $0.id == b.id })?.autoStartOnLaunch == true, "Automatic startup preference persists independently for each tunnel")
        engine.stopAll()
        try await IntegrationTests.wait("Stop all closes automatically started tunnels") { engine.activeCount == 0 }
        engine.startConfiguredTunnelsOnLaunch()
        try await Task.sleep(nanoseconds: 120_000_000)
        try IntegrationTests.expect(engine.activeCount == 0, "Reopening a window cannot rerun the per-process automatic startup batch")
        await engine.shutdown()
        let relaunched = TunnelEngine(store: store, tools: tools)
        relaunched.startConfiguredTunnelsOnLaunch()
        try await IntegrationTests.wait("Relaunched app honors the changed per-tunnel selections") { relaunched.session(for: b.id).status == .running }
        try IntegrationTests.expect(relaunched.session(for: a.id).status == .stopped, "A previously opted-in tunnel stays closed after opting out")
        await relaunched.shutdown()
        let broken = try profile("broken", auto: true, namespace: "broken"), good = try profile("good", auto: true)
        let failureStore = ProfileStore(url: root.appendingPathComponent("failure/profiles.json")); try failureStore.save([broken, good])
        let failureEngine = TunnelEngine(store: failureStore, tools: tools); failureEngine.startConfiguredTunnelsOnLaunch()
        try await IntegrationTests.wait("One failed automatic connection does not block another selected tunnel") { failureEngine.session(for: broken.id).status == .failed && failureEngine.session(for: good.id).status == .running }
        await failureEngine.shutdown()
        let delayed = root.appendingPathComponent("delayed-import.yaml"); try Data("test-only".utf8).write(to: delayed)
        let waiting = try profile("cancel-pending", auto: true, file: delayed)
        let waitingStore = ProfileStore(url: root.appendingPathComponent("waiting/profiles.json")); try waitingStore.save([waiting])
        let waitingEngine = TunnelEngine(store: waitingStore, tools: tools)
        waitingEngine.startConfiguredTunnelsOnLaunch()
        try IntegrationTests.expect(waitingEngine.pendingAutomaticStartup && waitingEngine.canStopAll && waitingEngine.activeCount == 0, "Stop-all controls remain available while automatic startup waits for import")
        waitingEngine.stopAll()
        try IntegrationTests.expect(!waitingEngine.pendingAutomaticStartup && !waitingEngine.canStopAll, "Cancelling pending startup immediately clears the stop-all UI state")
        try await IntegrationTests.wait("Config import may finish after pending auto-start is cancelled") { !waitingEngine.importingConfigs }
        try await Task.sleep(nanoseconds: 120_000_000)
        try IntegrationTests.expect(waitingEngine.session(for: waiting.id).status == .stopped, "Stop all cancels pending automatic startup before imports finish")
        await waitingEngine.shutdown()
        let slow = root.appendingPathComponent("slow-import.yaml"); try Data("test-only".utf8).write(to: slow)
        let quitting = try profile("quit-pending", auto: true, file: slow)
        let quitStore = ProfileStore(url: root.appendingPathComponent("quit/profiles.json")); try quitStore.save([quitting])
        let quitEngine = TunnelEngine(store: quitStore, tools: tools); quitEngine.startConfiguredTunnelsOnLaunch()
        try await Task.sleep(nanoseconds: 100_000_000)
        await quitEngine.shutdown()
        try IntegrationTests.expect(quitEngine.activeCount == 0 && quitEngine.session(for: quitting.id).status == .stopped, "App shutdown cancels startup and import without opening a late tunnel")
    }
}

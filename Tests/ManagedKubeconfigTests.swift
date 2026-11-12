import Foundation

enum ManagedKubeconfigTests {
    @MainActor static func run(fake: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TunnelDesk-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original config.json")
        func config(token: String = "SYNTHETIC_IMPORT_TOKEN") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["apiVersion": "v1", "kind": "Config", "clusters": [["name": "test", "cluster": ["server": "https://test.invalid"]]], "contexts": [["name": "test-context", "context": ["cluster": "test", "user": "test"]]], "users": [["name": "test", "user": ["token": token]]], "current-context": "test-context"], options: [.withoutEscapingSlashes])
        }
        try config().write(to: source)
        let store = ProfileStore(url: root.appendingPathComponent("profiles.json"))
        let tools = ToolPaths(kubectl: fake, ssh: fake)
        let engine = TunnelEngine(store: store, tools: tools)
        var original = TunnelProfile(); original.name = "managed"; original.kind = .kubernetes
        original.kubeconfig = source.path; original.namespace = "test"; original.context = "test-context"
        original.resource = "pod/test"; original.localPort = try IntegrationTests.availablePort(); original.remotePort = "80"
        try await engine.save(original)
        var saved = engine.profiles[0]
        let managed = saved.kubeconfig
        try IntegrationTests.expect(managed != source.path && engine.kubeconfigs.isManaged(managed, for: original.id), "Saving imports kubeconfig into a private app-owned file")
        let attributes = try FileManager.default.attributesOfItem(atPath: managed)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: engine.kubeconfigs.directory.path)
        try IntegrationTests.expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 && (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "Imported credentials are owner-readable only in an owner-only folder")
        try FileManager.default.removeItem(at: source)
        engine.start(original)
        try await IntegrationTests.wait("Tunnel starts from imported copy after deleting original file") { engine.runningCount == 1 }
        engine.stop(saved)
        try await IntegrationTests.wait("Imported tunnel shuts down normally") { engine.activeCount == 0 }
        let restarted = TunnelEngine(store: store, tools: tools)
        try IntegrationTests.expect(!restarted.importingConfigs && restarted.profiles[0].kubeconfig == managed, "Relaunch keeps imported copy without requiring original file")
        var duplicate = saved; duplicate.id = UUID(); duplicate.name = "duplicate"; duplicate.localPort = try IntegrationTests.availablePort()
        try await engine.save(duplicate)
        let duplicatePath = engine.profiles.first { $0.id == duplicate.id }!.kubeconfig
        engine.remove(original)
        try IntegrationTests.expect(!FileManager.default.fileExists(atPath: managed) && FileManager.default.isReadableFile(atPath: duplicatePath), "Deleting a stale pre-import profile removes the current copy without breaking a duplicate")
        saved = engine.profiles[0]
        try config(token: "SYNTHETIC_REPLACEMENT_TOKEN").write(to: source)
        var replacement = saved; replacement.kubeconfig = source.path
        try await engine.save(replacement)
        let replacementPath = engine.profiles[0].kubeconfig
        try IntegrationTests.expect(replacementPath != duplicatePath && !FileManager.default.fileExists(atPath: duplicatePath) && FileManager.default.fileExists(atPath: source.path), "Replacing config cleans old app copy and preserves user's source file")
        let invalid = root.appendingPathComponent("invalid.json"); try Data("invalid".utf8).write(to: invalid)
        var bad = engine.profiles[0]; bad.kubeconfig = invalid.path
        do { try await engine.save(bad); throw TunnelError("Invalid import accepted") }
        catch let e as TunnelError { try IntegrationTests.expect(!e.message.contains("SECRET-SHOULD-NOT-LEAK") && e.message.contains("aktarılamadı"), "Failed import errors never include credential-bearing command output") }
        try IntegrationTests.expect(engine.profiles[0].kubeconfig == replacementPath && FileManager.default.isReadableFile(atPath: replacementPath), "Failed config replacement preserves last saved connection")
        let rollbackStore = ProfileStore(url: root.appendingPathComponent("rollback/profiles.json"))
        let rollbackEngine = TunnelEngine(store: rollbackStore, tools: tools)
        try FileManager.default.createDirectory(at: rollbackStore.url, withIntermediateDirectories: true)
        do { try await rollbackEngine.save(original); throw TunnelError("Profile save should fail") }
        catch {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: rollbackEngine.kubeconfigs.directory.path)) ?? []
            try IntegrationTests.expect(rollbackEngine.profiles.isEmpty && files.isEmpty, "Profile write failure rolls back newly imported credential file")
        }
        let migrationStore = ProfileStore(url: root.appendingPathComponent("legacy/profiles.json"))
        try migrationStore.save([original])
        let migrationEngine = TunnelEngine(store: migrationStore, tools: tools)
        try await IntegrationTests.wait("Legacy profile kubeconfig imports automatically on launch") { !migrationEngine.importingConfigs }
        let migrated = migrationEngine.profiles[0]
        try IntegrationTests.expect(migrationEngine.kubeconfigs.isManaged(migrated.kubeconfig) && migrated.id == original.id && migrated.namespace == original.namespace && migrated.context == original.context, "Legacy import preserves tunnel identity, context and namespace")
        let missingStore = ProfileStore(url: root.appendingPathComponent("missing/profiles.json"))
        var missing = original; missing.kubeconfig = root.appendingPathComponent("missing-original.yaml").path
        try missingStore.save([missing])
        let missingEngine = TunnelEngine(store: missingStore, tools: tools)
        try await IntegrationTests.wait("Missing legacy source finishes migration with a visible notice") { !missingEngine.importingConfigs }
        try IntegrationTests.expect(missingEngine.notice != nil && (try missingStore.load()) == [missing], "Missing legacy source does not destroy existing profile")
        let large = root.appendingPathComponent("large.json"); try config(token: String(repeating: "x", count: 350_000)).write(to: large)
        let largePath = try await engine.kubeconfigs.importFile(large.path, for: UUID(), kubectl: fake)
        let largeData = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: largePath))) as! [String: Any]
        let largeUser = (largeData["users"] as! [[String: Any]])[0]["user"] as! [String: Any]
        try IntegrationTests.expect((largeUser["token"] as? String)?.count == 350_000, "Large kubeconfigs are captured completely without log-buffer truncation")
        let slowSource = root.appendingPathComponent("slow-import.json"); try config().write(to: slowSource)
        let cancelEngine = TunnelEngine(store: ProfileStore(url: root.appendingPathComponent("cancel/profiles.json")), tools: tools)
        var slow = original; slow.kubeconfig = slowSource.path
        let task = Task { try await cancelEngine.save(slow) }
        try await IntegrationTests.wait("Import exposes its in-progress state") { cancelEngine.importingConfigs }
        try await Task.sleep(nanoseconds: 100_000_000); task.cancel()
        do { try await task.value; throw TunnelError("Cancelled import saved a profile") } catch is CancellationError {}
        try IntegrationTests.expect(cancelEngine.profiles.isEmpty && !cancelEngine.importingConfigs, "Cancelling import leaves no saved profile or stuck UI state")
        let quittingEngine = TunnelEngine(store: ProfileStore(url: root.appendingPathComponent("quit/profiles.json")), tools: tools)
        let saveTask = Task { try await quittingEngine.save(slow) }
        try await IntegrationTests.wait("Save is in progress before app shutdown") { quittingEngine.importingConfigs }
        try await Task.sleep(nanoseconds: 100_000_000)
        await quittingEngine.shutdown()
        do { try await saveTask.value; throw TunnelError("Shutdown did not cancel save") } catch is CancellationError {}
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: quittingEngine.kubeconfigs.directory.path)) ?? []
        try IntegrationTests.expect(quittingEngine.profiles.isEmpty && remaining.isEmpty && !quittingEngine.importingConfigs, "Shutdown awaits imports and leaves no orphan credential snapshot")
        if let realKubectl = ToolPaths.detected.kubectl { try await checkFlatten(root: root, kubectl: realKubectl, store: engine.kubeconfigs) }
    }
    static func checkFlatten(root: URL, kubectl: String, store: KubeconfigStore) async throws {
        let assets = root.appendingPathComponent("external-certs")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let ca = Data("SYNTHETIC_CA".utf8), cert = Data("SYNTHETIC_CERT".utf8), key = Data("SYNTHETIC_KEY".utf8)
        try ca.write(to: assets.appendingPathComponent("ca.pem")); try cert.write(to: assets.appendingPathComponent("client.pem")); try key.write(to: assets.appendingPathComponent("client-key.pem"))
        try Data("SYNTHETIC_FILE_TOKEN\n".utf8).write(to: assets.appendingPathComponent("token.txt"))
        let source = assets.appendingPathComponent("kubeconfig.json")
        let object: [String: Any] = ["apiVersion": "v1", "kind": "Config", "clusters": [["name": "offline", "cluster": ["server": "https://offline.invalid", "certificate-authority": "ca.pem"]]], "contexts": [["name": "offline", "context": ["cluster": "offline", "user": "offline"]]], "users": [["name": "offline", "user": ["client-certificate": "client.pem", "client-key": "client-key.pem", "tokenFile": "token.txt"]], ["name": "relative-plugin", "user": ["exec": ["command": "./plugins/login", "apiVersion": "client.authentication.k8s.io/v1beta1", "interactiveMode": "Never"]]], ["name": "path-plugin", "user": ["exec": ["command": "fixture-login", "apiVersion": "client.authentication.k8s.io/v1beta1", "interactiveMode": "Never"]]]], "current-context": "offline"]
        try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]).write(to: source)
        let imported = try await store.importFile(source.path, for: UUID(), kubectl: kubectl)
        try FileManager.default.removeItem(at: assets)
        let result = try await CommandExecutor.run(kubectl, ["--kubeconfig", imported, "config", "view", "--raw", "--flatten", "-o", "json"], captureLimit: nil, discardStderr: true)
        try IntegrationTests.expect(result.code == 0, "Real kubectl can read imported config after original config and external credential files are deleted")
        let flattened = try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as! [String: Any]
        let cluster = (flattened["clusters"] as! [[String: Any]])[0]["cluster"] as! [String: Any]
        let user = (flattened["users"] as! [[String: Any]])[0]["user"] as! [String: Any]
        try IntegrationTests.expect(cluster["certificate-authority-data"] as? String == ca.base64EncodedString() && user["client-certificate-data"] as? String == cert.base64EncodedString() && user["client-key-data"] as? String == key.base64EncodedString() && user["token"] as? String == "SYNTHETIC_FILE_TOKEN" && user["tokenFile"] == nil, "Certificates, private keys and token-file credentials are embedded without redaction")
        let users = flattened["users"] as! [[String: Any]]
        let relative = users.first { $0["name"] as? String == "relative-plugin" }!["user"] as! [String: Any]
        let path = users.first { $0["name"] as? String == "path-plugin" }!["user"] as! [String: Any]
        try IntegrationTests.expect((relative["exec"] as? [String: Any])?["command"] as? String == assets.appendingPathComponent("plugins/login").standardizedFileURL.path && (path["exec"] as? [String: Any])?["command"] as? String == "fixture-login", "Relative auth-plugin paths retain their original resolution and PATH commands remain unchanged")
    }
}

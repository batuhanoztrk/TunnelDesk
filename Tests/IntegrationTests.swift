import Foundation
import Darwin

@main
struct IntegrationTests {
    @MainActor static func main() async {
        do { try await run(); print("ALL INTEGRATION CHECKS PASSED") }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw TunnelError(message) }
        print("PASS: \(message)")
    }
    @MainActor static func wait(_ message: String, timeout: Double = 7, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw TunnelError("Timeout: \(message)") }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        print("PASS: \(message)")
    }
    static func availablePort() throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TunnelError("test socket") }
        defer { close(fd) }
        var addr = sockaddr_in(); addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw TunnelError("test bind") }
        var count = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &count) } }
        return String(UInt16(bigEndian: addr.sin_port))
    }
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("TunnelDesk-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let config = temporary.appendingPathComponent("config with spaces.yaml")
        try Data("test-only".utf8).write(to: config)
        let fake = root.appendingPathComponent("Tests/fake-kubectl.py").path
        let trace = temporary.appendingPathComponent("trace.jsonl")
        setenv("TUNNELDESK_TEST_TRACE", trace.path, 1)
        let engine = TunnelEngine(store: ProfileStore(url: temporary.appendingPathComponent("profiles.json")), tools: ToolPaths(kubectl: fake, ssh: fake))
        defer { engine.stopAll() }
        try expect(engine.profiles.isEmpty, "Fresh application contains no preset tunnels")
        func profile(_ name: String, kind: TunnelKind = .kubernetes, namespace: String = "test") throws -> TunnelProfile {
            var p = TunnelProfile(); p.name = name; p.kind = kind; p.localPort = try availablePort()
            p.kubeconfig = config.path; p.context = "test-context"; p.namespace = namespace
            p.resource = "pod/test-server"; p.remoteHost = "192.0.2.10"; p.remotePort = "1433"; p.sshHost = "test-ssh"; p.sshUser = "tester"
            return p
        }
        var a = try profile("first"), b = try profile("second")
        try await engine.save(a); try await engine.save(b)
        a = engine.profiles.first { $0.id == a.id }!; b = engine.profiles.first { $0.id == b.id }!
        try expect(try engine.store.load() == [a, b], "Profiles round-trip through persistent JSON with spaces in file paths")
        var invalid = a; invalid.remoteHost = "host;touch /tmp/injected"; invalid.kind = .relay
        do { try invalid.validate(); throw TunnelError("Injection validation failed") } catch let e as TunnelError { try expect(e.message.contains("hedef"), "Invalid relay hosts rejected without shell execution") }
        let contexts = try await engine.loadContexts(kubeconfig: config.path)
        try expect(contexts == ["test-context", "second-context"], "Context picker reads config without exposing credentials")
        let namespaces = try await engine.loadNamespaces(profile: a)
        try expect(namespaces == ["team-alpha", "team-beta"], "Namespace discovery falls back to named RBAC grants")
        engine.startAll()
        try await wait("Two forwards run concurrently, including split readiness messages") { engine.runningCount == 2 }
        do { try LocalPort.ensureAvailable(TunnelProfile.port(a.localPort)!); throw TunnelError("Port conflict undetected") }
        catch let e as TunnelError { try expect(e.message.contains("kullanılıyor"), "An existing listener is detected without stopping it") }
        var conflict = try profile("conflict"); conflict.localPort = a.localPort; try await engine.save(conflict); engine.start(conflict)
        try expect(engine.session(for: conflict.id).status == .failed, "A duplicate local port produces a visible failure")
        try expect(engine.session(for: a.id).status == .running, "Port conflicts do not terminate another tunnel")
        engine.stopAll()
        try await wait("Stop all releases every owned forwarding process") { engine.activeCount == 0 }
        try LocalPort.ensureAvailable(TunnelProfile.port(a.localPort)!)
        try LocalPort.ensureAvailable(TunnelProfile.port(b.localPort)!)
        let relay = try profile("relay", kind: .relay); try await engine.save(relay)
        engine.start(relay)
        try await wait("Relay creates a pod and starts its forward") { engine.session(for: relay.id).status == .running }
        let pod = engine.session(for: relay.id).relayName!
        let manifest = try JSONSerialization.jsonObject(with: relay.relayManifest(name: pod)) as! [String: Any]
        let spec = manifest["spec"] as! [String: Any]
        try expect(spec["automountServiceAccountToken"] as? Bool == false, "Relay does not mount cluster credentials")
        engine.stop(relay)
        try await wait("Stopping a relay cleans its pod") { engine.session(for: relay.id).status == .stopped }
        let lines = try String(contentsOf: trace, encoding: .utf8).split(whereSeparator: \.isNewline)
        let commands = try lines.map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) }
        let deletion = commands.first { $0.contains("delete") && $0.contains("--field-selector=metadata.name=\(pod)") }
        try expect(deletion?.contains("--selector=app.kubernetes.io/managed-by=tunneldesk,tunneldesk-profile=\(relay.id.uuidString.lowercased())") == true, "Pod cleanup requires exact ownership labels and pod name")
        let slow = try profile("cancel", kind: .relay, namespace: "slow"); try await engine.save(slow); engine.start(slow)
        try await wait("Slow relay reaches preparation") { engine.session(for: slow.id).relayName != nil }
        try await Task.sleep(nanoseconds: 150_000_000)
        engine.stop(slow)
        try await wait("Stopping during preparation cancels the command and cleans the pod") { engine.session(for: slow.id).status == .stopped }
        let broken = try profile("broken", namespace: "broken"); try await engine.save(broken); engine.start(broken)
        try await wait("Unexpected forwarding exit becomes a visible error") { engine.session(for: broken.id).status == .failed }
        try expect(engine.session(for: broken.id).error?.contains("target pod not found") == true, "Actionable subprocess failure reaches the UI")
        let ssh = try profile("ssh", kind: .ssh); try await engine.save(ssh); engine.start(ssh)
        try expect(["ControlMaster=no", "ControlPath=none", "ControlPersist=no", "ForkAfterAuthentication=no"].allSatisfy { ssh.forwardArguments().contains($0) }, "SSH config cannot move owned forwarding into a persistent background master")
        try await wait("SSH forwarding reaches running state") { engine.session(for: ssh.id).status == .running }
        let stranded = try profile("cleanup-denied", kind: .relay, namespace: "cleanup-denied"); try await engine.save(stranded); engine.start(stranded)
        try await wait("Relay with denied deletion starts normally") { engine.session(for: stranded.id).status == .running }
        engine.stop(stranded)
        try await wait("Denied pod cleanup remains visible and retryable") { engine.session(for: stranded.id).status == .failed }
        try expect(engine.session(for: stranded.id).relayName != nil, "Cleanup ownership is retained when pod deletion fails")
        var edited = stranded; edited.namespace = "elsewhere"
        do { try await engine.save(edited); throw TunnelError("Editing stranded relay was permitted") }
        catch let e as TunnelError { try expect(e.message.contains("podunu temizle"), "Editing cannot strand cleanup in the original namespace") }
        let backgroundLookup = Task { try await CommandExecutor.run("/bin/sleep", ["20"], timeout: 30) }
        try await Task.sleep(nanoseconds: 100_000_000)
        await engine.shutdown()
        let lookupResult = try await backgroundLookup.value
        try expect(lookupResult.code != 0, "Shutdown also terminates commands owned by editor lookups")
        try expect(engine.activeCount == 0, "App shutdown stops all tunnel processes")
        await engine.shutdown()
        try expect(engine.activeCount == 0, "Repeated shutdown during updater relaunch is safe and idempotent")
        await engine.resumeAfterCancelledUpdate()
        try expect(!engine.shuttingDown, "Aborted update can recover from the cleanup state")
        engine.start(a)
        try await wait("Tunnel can be opened again after an aborted update") { engine.session(for: a.id).status == .running }
        await engine.shutdown()
        try LocalPort.ensureAvailable(TunnelProfile.port(ssh.localPort)!)
        let started = Date()
        let timed = try await CommandExecutor.run("/bin/sleep", ["20"], timeout: 0.15)
        try expect(timed.code != 0 && Date().timeIntervalSince(started) < 4, "Command deadline terminates a stuck child process")
        do { _ = try await CommandExecutor.run("/nonexistent/tunneldesk-tool", [], timeout: 1); throw TunnelError("Missing command was accepted") }
        catch { try expect(!error.localizedDescription.isEmpty, "Missing command reports launch failure") }
        try await ManagedKubeconfigTests.run(fake: fake)
        let corrupt = temporary.appendingPathComponent("corrupt.json"); try Data("invalid JSON".utf8).write(to: corrupt)
        let damaged = TunnelEngine(store: ProfileStore(url: corrupt))
        do { try await damaged.save(a); throw TunnelError("Corrupt storage overwritten") }
        catch { try expect(try String(contentsOf: corrupt, encoding: .utf8) == "invalid JSON", "Unreadable profile storage is preserved") }
    }
}

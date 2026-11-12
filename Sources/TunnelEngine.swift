import Foundation
import Combine

@MainActor
final class TunnelSession: ObservableObject {
    @Published var status: TunnelStatus = .stopped
    @Published var log = ""
    @Published var error: String?
    @Published var startedAt: Date?
    var generation = UUID()
    var forward: Subprocess?
    var operation: Task<Void, Never>?
    var stopOperation: Task<Void, Never>?
    var readyTimeout: Task<Void, Never>?
    var relayName: String?
    var readinessBuffer = ""
    func append(_ message: String) {
        log += message
        if !message.hasSuffix("\n") { log += "\n" }
        if log.count > 60_000 { log = String(log.suffix(50_000)) }
    }
}

@MainActor
final class TunnelEngine: ObservableObject {
    @Published private(set) var profiles: [TunnelProfile] = []
    @Published var selectedID: UUID?
    @Published var notice: String?
    @Published private(set) var revision = 0
    @Published private(set) var shuttingDown = false
    @Published private(set) var importingConfigs = false
    let tools: ToolPaths
    let store: ProfileStore
    let kubeconfigs: KubeconfigStore
    private var sessions: [UUID: TunnelSession] = [:]
    private var subscriptions: [UUID: AnyCancellable] = [:]
    private var storageValid = true
    private var migration: Task<Void, Never>?
    private var saving: Task<Void, Error>?

    init(store: ProfileStore = ProfileStore(), tools: ToolPaths = .detected) {
        self.store = store; self.tools = tools; self.kubeconfigs = KubeconfigStore(profileStore: store)
        do { profiles = try store.load() }
        catch { storageValid = false; notice = "Tünel kayıtları okunamadı. Mevcut dosyanın üzerine yazılmadı.\n\(error.localizedDescription)\n\(store.url.path)" }
        if profiles.contains(where: { $0.kind != .ssh && !kubeconfigs.isManaged($0.kubeconfig, for: $0.id) }) {
            importingConfigs = true
            migration = Task { [weak self] in await self?.migrateKubeconfigs() }
        }
    }
    var runningCount: Int { profiles.filter { session(for: $0.id).status == .running }.count }
    var activeCount: Int { profiles.filter { session(for: $0.id).status.busy }.count }
    var selected: TunnelProfile? { profiles.first { $0.id == selectedID } }
    func session(for id: UUID) -> TunnelSession {
        if let existing = sessions[id] { return existing }
        let session = TunnelSession(); sessions[id] = session
        subscriptions[id] = session.objectWillChange.sink { [weak self] _ in
            // Publish after the session's @Published value has changed.
            Task { @MainActor in self?.revision &+= 1 }
        }
        return session
    }
    func save(_ raw: TunnelProfile) async throws {
        guard storageValid else { throw TunnelError("Kayıt dosyası okunamadığı için kaydetme kapalı. ‘Tüneller’ menüsünden kayıt dosyasını kontrol edip uygulamayı yeniden aç.") }
        guard !shuttingDown else { throw CancellationError() }
        guard !importingConfigs else { throw TunnelError("Kubeconfig içeri aktarma işleminin tamamlanmasını bekle.") }
        importingConfigs = true; defer { importingConfigs = false; saving = nil }
        let task = Task { try await self.persistImported(raw.normalized()) }
        saving = task
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func persistImported(_ raw: TunnelProfile) async throws {
        var profile = raw
        try profile.validate()
        let state = session(for: profile.id)
        guard !state.status.busy && state.relayName == nil else { throw TunnelError("Düzenlemeden önce tüneli kapat ve varsa geçici podunu temizle.") }
        let previous = profiles.first(where: { $0.id == profile.id })?.kubeconfig
        if profile.kind == .ssh { profile.kubeconfig = "" }
        else { profile.kubeconfig = try await kubeconfigs.importFile(profile.kubeconfig, for: profile.id, kubectl: tools.kubectl) }
        var updated = profiles
        if let index = updated.firstIndex(where: { $0.id == profile.id }) { updated[index] = profile }
        else { updated.append(profile) }
        do {
            try Task.checkCancellation()
            guard !shuttingDown else { throw CancellationError() }
            try store.save(updated)
        } catch {
            try? kubeconfigs.removeIfUnused(profile.kubeconfig, profiles: profiles)
            throw error
        }
        profiles = updated; selectedID = profile.id
        if let previous, previous != profile.kubeconfig {
            do { try kubeconfigs.removeIfUnused(previous, profiles: profiles) }
            catch { notice = "Bağlantı kaydedildi; eski kubeconfig kopyası temizlenemedi." }
        }
    }
    private func migrateKubeconfigs() async {
        defer { importingConfigs = false; migration = nil }
        let originalSelection = selectedID
        var failures: [String] = []
        for profile in profiles where profile.kind != .ssh && !kubeconfigs.isManaged(profile.kubeconfig, for: profile.id) {
            if Task.isCancelled || shuttingDown { break }
            do { try await persistImported(profile) }
            catch is CancellationError { break }
            catch { failures.append("\(profile.name): \(error.localizedDescription)") }
        }
        selectedID = originalSelection
        if !failures.isEmpty { notice = "Bazı mevcut kubeconfig dosyaları içeri aktarılamadı. Bu bağlantıları düzenleyip dosyayı yeniden seçebilirsin.\n" + failures.joined(separator: "\n") }
    }
    func remove(_ profile: TunnelProfile) {
        guard !importingConfigs else { notice = "Kubeconfig içeri aktarma işleminin tamamlanmasını bekle."; return }
        guard let profile = profiles.first(where: { $0.id == profile.id }) else { return }
        let state = session(for: profile.id)
        guard !state.status.busy && state.relayName == nil else { notice = "Silmeden önce tüneli ve geçici podunu kapat."; return }
        let updated = profiles.filter { $0.id != profile.id }
        do {
            try store.save(updated); profiles = updated
            do { try kubeconfigs.removeIfUnused(profile.kubeconfig, profiles: profiles) }
            catch { notice = "Tünel silindi; kayıtlı kubeconfig kopyası temizlenemedi." }
            sessions.removeValue(forKey: profile.id); subscriptions.removeValue(forKey: profile.id)
            if selectedID == profile.id { selectedID = profiles.first?.id }
        } catch { notice = "Tünel silinemedi: \(error.localizedDescription)" }
    }
    func startAll() {
        for profile in profiles where !session(for: profile.id).status.busy { start(profile) }
    }
    func stopAll() {
        for profile in profiles {
            let state = session(for: profile.id)
            if state.status.busy || state.relayName != nil { stop(profile) }
        }
    }
    func start(_ profile: TunnelProfile) {
        guard !shuttingDown else { return }
        guard !importingConfigs else { notice = "Kubeconfig içeri aktarma işleminin tamamlanmasını bekle."; return }
        // Always use the stored, imported profile even when a caller retained its pre-import value.
        let profile = profiles.first(where: { $0.id == profile.id }) ?? profile
        let state = session(for: profile.id)
        guard !state.status.busy else { return }
        do {
            try profile.validate()
            guard let port = TunnelProfile.port(profile.localPort) else { return }
            let collision = profiles.first { $0.id != profile.id && $0.localPort == profile.localPort && session(for: $0.id).status.busy }
            if let collision { throw TunnelError("\(profile.localPort) portu ‘\(collision.name)’ tüneline ayrılmış. Farklı bir yerel port seç.") }
            try LocalPort.ensureAvailable(port)
            guard profile.kind == .ssh ? tools.ssh != nil : tools.kubectl != nil else {
                throw TunnelError(profile.kind == .ssh ? "ssh bulunamadı." : "kubectl bulunamadı. Homebrew ile kubectl kurup uygulamayı yeniden aç.")
            }
        } catch { state.error = error.localizedDescription; state.status = .failed; state.append(error.localizedDescription); return }
        let generation = UUID(); state.generation = generation
        state.error = nil; state.startedAt = nil; state.readinessBuffer = ""; state.status = .preparing
        state.append("\n── \(Date().formatted(date: .omitted, time: .standard)) · \(profile.name) açılıyor ──")
        state.operation = Task { [weak self, weak state] in
            guard let self, let state else { return }
            do {
                if state.relayName != nil { try await self.cleanup(profile, state: state) }
                if profile.kind == .relay { try await self.prepareRelay(profile, state: state) }
                try Task.checkCancellation()
                guard state.generation == generation else { return }
                try self.launchForward(profile, state: state, generation: generation)
            } catch is CancellationError {
                // stop() owns cleanup and the final state after cancellation.
            } catch {
                guard state.generation == generation, state.status != .stopping else { return }
                let message = error.localizedDescription
                state.append(message)
                do { try await self.cleanup(profile, state: state) }
                catch { state.append("Pod temizlenemedi: \(error.localizedDescription)") }
                guard state.generation == generation, state.status != .stopping else { return }
                state.error = message; state.status = .failed
            }
            if state.generation == generation { state.operation = nil }
        }
    }
    private func prepareRelay(_ profile: TunnelProfile, state: TunnelSession) async throws {
        guard let kubectl = tools.kubectl else { throw TunnelError("kubectl bulunamadı.") }
        let name = profile.relayPrefix + "-" + UUID().uuidString.lowercased().prefix(8)
        // Record before create: if the request is interrupted, selector-scoped cleanup is still safe.
        state.relayName = name
        state.append("Geçici TCP podu oluşturuluyor: \(profile.namespace)/\(name)")
        _ = try await CommandExecutor.run(kubectl, profile.kubectlArguments(["create", "-f", "-"]), input: profile.relayManifest(name: name)).checked()
        state.append("Podun hazır olması bekleniyor (en fazla 90 saniye).")
        do {
            _ = try await CommandExecutor.run(kubectl, profile.kubectlArguments(["wait", "--for=condition=Ready", "pod/\(name)", "--timeout=90s"], timed: false), timeout: 100).checked()
        } catch {
            if !Task.isCancelled {
                if let result = try? await CommandExecutor.run(kubectl, profile.kubectlArguments(["get", "pod", name, "-o", "jsonpath={.status.phase}{' '}{.status.containerStatuses[*].state}"]), timeout: 25) { state.append(result.output) }
            }
            throw error
        }
    }
    private func launchForward(_ profile: TunnelProfile, state: TunnelSession, generation: UUID) throws {
        guard let executable = profile.kind == .ssh ? tools.ssh : tools.kubectl else { throw TunnelError("Bağlantı aracı bulunamadı.") }
        state.status = .starting
        let command = Subprocess(executable: executable, arguments: profile.forwardArguments(relayName: state.relayName))
        state.forward = command
        command.onOutput = { [weak state] text in
            Task { @MainActor in
                guard let state, state.generation == generation, state.status != .stopping else { return }
                state.append(text)
                state.readinessBuffer = String((state.readinessBuffer + text).suffix(8192))
                if state.status == .starting && (state.readinessBuffer.contains("Forwarding from 127.0.0.1:") || state.readinessBuffer.contains("Local forwarding listening on 127.0.0.1")) {
                    state.status = .running; state.startedAt = Date(); state.readyTimeout?.cancel(); state.readyTimeout = nil
                }
            }
        }
        command.onExit = { [weak self, weak state] result in
            Task { @MainActor in
                guard let self, let state, state.generation == generation else { return }
                state.forward = nil; state.readyTimeout?.cancel(); state.readyTimeout = nil
                guard state.status != .stopping else { return }
                let message = result.output.trimmed.isEmpty ? "Tünel bağlantısı kapandı (\(result.code))." : result.output.trimmed
                self.stop(profile, finalError: message)
            }
        }
        do { try command.start() }
        catch { state.forward = nil; throw error }
        state.readyTimeout = Task { [weak self, weak state] in
            do { try await Task.sleep(nanoseconds: 45_000_000_000) } catch { return }
            guard let self, let state, state.generation == generation, state.status == .starting else { return }
            self.stop(profile, finalError: "Bağlantı 45 saniyede açılamadı. Günlüğü kontrol et.")
        }
    }
    func stop(_ profile: TunnelProfile, finalError: String? = nil) {
        let state = session(for: profile.id)
        guard state.stopOperation == nil else { return }
        guard state.status.busy || state.relayName != nil else { return }
        state.status = .stopping
        state.readyTimeout?.cancel(); state.readyTimeout = nil
        let operation = state.operation; operation?.cancel()
        let forward = state.forward; forward?.stop()
        state.stopOperation = Task { [weak self, weak state] in
            guard let self, let state else { return }
            await operation?.value
            // Wait for child termination before making the port available in the UI.
            if let forward {
                for _ in 0..<40 {
                    if !forward.process.isRunning { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            state.forward = nil; state.operation = nil; state.startedAt = nil
            do {
                try await self.cleanup(profile, state: state)
                state.status = finalError == nil ? .stopped : .failed
                state.error = finalError
                state.append(finalError ?? "Tünel kapatıldı.")
            } catch {
                state.status = .failed
                state.error = "Yerel tünel kapandı; geçici pod temizlenemedi. ‘Podu temizle’ ile yeniden deneyebilirsin.\n\(error.localizedDescription)"
                state.append(state.error!)
            }
            state.stopOperation = nil
        }
    }
    private func cleanup(_ profile: TunnelProfile, state: TunnelSession) async throws {
        guard let name = state.relayName else { return }
        guard let kubectl = tools.kubectl else { throw TunnelError("Pod temizliği için kubectl bulunamadı.") }
        state.append("Yalnızca bu tünelin oluşturduğu geçici pod temizleniyor.")
        _ = try await CommandExecutor.run(kubectl, profile.cleanupArguments(name: name), timeout: 25).checked()
        if state.relayName == name { state.relayName = nil }
    }
    func shutdown() async {
        shuttingDown = true
        let activeSave = saving
        activeSave?.cancel()
        migration?.cancel()
        _ = try? await activeSave?.value
        await migration?.value
        stopAll()
        let tasks = sessions.values.compactMap(\.stopOperation)
        for task in tasks { await task.value }
        // Includes context/namespace lookups opened from an editor sheet.
        await Subprocess.stopAllOwnedCommands()
    }
    func loadContexts(kubeconfig: String) async throws -> [String] {
        guard !shuttingDown else { throw CancellationError() }
        guard let kubectl = tools.kubectl else { throw TunnelError("kubectl bulunamadı.") }
        let result = try await CommandExecutor.run(kubectl, ["--kubeconfig", kubeconfig.expandingTilde, "config", "get-contexts", "-o", "name"], timeout: 10).checked()
        return result.output.split(whereSeparator: \.isNewline).map(String.init)
    }
    func loadNamespaces(profile: TunnelProfile) async throws -> [String] {
        guard !shuttingDown else { throw CancellationError() }
        guard let kubectl = tools.kubectl else { throw TunnelError("kubectl bulunamadı.") }
        var args = ["--kubeconfig", profile.kubeconfig.expandingTilde]
        if !profile.context.isEmpty { args += ["--context", profile.context] }
        args += ["--request-timeout=15s", "get", "namespaces", "-o", "jsonpath={.items[*].metadata.name}"]
        let result = try await CommandExecutor.run(kubectl, args, timeout: 20)
        if result.code == 0 { return result.output.split(whereSeparator: \.isWhitespace).map(String.init).sorted() }
        guard !shuttingDown else { throw CancellationError() }
        // Namespace-scoped Rancher accounts cannot list all namespaces. Discover named grants locally via RBAC.
        let rules = try await CommandExecutor.run(kubectl, profile.kubectlArguments(["auth", "can-i", "--list"]), timeout: 25).checked()
        let names = rules.output.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("namespaces ") }.flatMap { line -> [String] in
            let brackets = String(line).components(separatedBy: "[")
            guard brackets.count >= 3 else { return [] }
            return brackets[2].components(separatedBy: "]")[0].split(separator: " ").map(String.init)
        }.filter { $0.matches("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$") }
        if !names.isEmpty { return Array(Set(names)).sorted() }
        throw TunnelError("Namespace listesi okunamadı. Hesabın listeleme yetkisi olmayabilir; namespace'i elle yazabilirsin.\n\(result.output.trimmed)")
    }
}

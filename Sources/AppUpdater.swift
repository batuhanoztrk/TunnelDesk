import AppKit
import SwiftUI
import Combine
import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = true
    @Published private(set) var automaticDownloads = true
    private var controller: SPUStandardUpdaterController!
    private var subscriptions = Set<AnyCancellable>()
    private weak var engine: TunnelEngine?
    private var started = false
    private var pendingRelaunch: UUID?

    init(engine: TunnelEngine) {
        self.engine = engine
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).sink { [weak self] in self?.canCheck = $0 }.store(in: &subscriptions)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: RunLoop.main).sink { [weak self] in self?.automaticChecks = $0 }.store(in: &subscriptions)
        controller.updater.publisher(for: \.automaticallyDownloadsUpdates).receive(on: RunLoop.main).sink { [weak self] in self?.automaticDownloads = $0 }.store(in: &subscriptions)
    }
    func start() {
        guard !started else { return }
        started = true
        controller.startUpdater()
    }
    func check() {
        guard canCheck else { return }
        controller.checkForUpdates(nil)
    }
    func setAutomaticChecks(_ enabled: Bool) { controller.updater.automaticallyChecksForUpdates = enabled }
    func setAutomaticDownloads(_ enabled: Bool) { controller.updater.automaticallyDownloadsUpdates = enabled }

    // Finish tunnel/pod cleanup and pending imports before Sparkle replaces and relaunches the app.
    @objc(updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard let engine else { return false }
        let request = UUID(); pendingRelaunch = request
        Task { @MainActor in
            await engine.shutdown()
            guard self.pendingRelaunch == request else { return }
            installHandler()
        }
        return true
    }
    @objc(updater:didAbortWithError:)
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        guard pendingRelaunch != nil, let engine else { return }
        pendingRelaunch = nil
        Task { @MainActor in
            await engine.resumeAfterCancelledUpdate()
            engine.notice = "Güncelleme tamamlanamadı. Uygulamayı kullanmaya devam edebilir, tünellerini yeniden açabilirsin."
        }
    }
}

struct UpdateSettingsView: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        Form {
            Section {
                Toggle("Yeni sürümleri otomatik kontrol et", isOn: Binding(get: { updater.automaticChecks }, set: updater.setAutomaticChecks))
                Toggle("Güncellemeleri otomatik indir ve çıkışta kur", isOn: Binding(get: { updater.automaticDownloads }, set: updater.setAutomaticDownloads))
            } footer: {
                Text("Güncellemeler GitHub release'lerinden indirilir ve imzaları doğrulanır. Kayıtlı tünellerin ve kubeconfig kopyaların korunur.")
            }
            Section {
                LabeledContent("Mevcut sürüm", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                Button("Güncellemeleri kontrol et…") { updater.check() }.disabled(!updater.canCheck)
                Link("GitHub sürümleri", destination: URL(string: "https://github.com/batuhanoztrk/TunnelDesk/releases")!)
            }
        }.formStyle(.grouped).padding(12).frame(width: 470, height: 290)
    }
}

import Foundation
import Combine
import ServiceManagement

@MainActor
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
    func openSettings()
}

struct SystemLoginItemService: LoginItemService {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() async throws { try await SMAppService.mainApp.unregister() }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
final class StartupPreferences: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var isUpdating = false
    @Published private(set) var error: String?
    private let service: any LoginItemService

    init(service: (any LoginItemService)? = nil) {
        let service = service ?? SystemLoginItemService()
        self.service = service
        status = service.status
    }
    var isEnabled: Bool { status == .enabled }
    var isRequested: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }
    func refresh() {
        guard !isUpdating else { return }
        let actual = service.status
        if status != actual { status = actual; error = nil }
    }
    func setEnabled(_ enabled: Bool) async {
        guard !isUpdating else { return }
        refresh()
        guard enabled != isRequested else { return }
        isUpdating = true; error = nil
        defer { status = service.status; isUpdating = false }
        do {
            if enabled { try service.register() }
            else { try await service.unregister() }
        } catch {
            if !enabled || service.status != .requiresApproval {
                self.error = "Otomatik başlatma değiştirilemedi: \(error.localizedDescription)"
            }
        }
    }
    func openSystemSettings() { service.openSettings() }
}

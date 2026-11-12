import Foundation
import ServiceManagement

@MainActor
private final class FakeLoginItemService: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    var nextStatus: SMAppService.Status = .enabled
    var registerCount = 0
    var unregisterCount = 0
    var openSettingsCount = 0
    var registrationError: Error?
    var removalError: Error?
    var delayedRemoval = false
    func register() throws {
        registerCount += 1
        if let registrationError { throw registrationError }
        status = nextStatus
    }
    func unregister() async throws {
        unregisterCount += 1
        if delayedRemoval { try await Task.sleep(nanoseconds: 100_000_000) }
        if let removalError { throw removalError }
        status = .notRegistered
    }
    func openSettings() { openSettingsCount += 1 }
}

enum StartupPreferenceTests {
    @MainActor static func run() async throws {
        let service = FakeLoginItemService()
        let settings = StartupPreferences(service: service)
        try IntegrationTests.expect(!settings.isRequested && service.registerCount == 0, "Launch-at-login is not registered merely by opening the app or settings")
        await settings.setEnabled(true)
        try IntegrationTests.expect(settings.isEnabled && settings.isRequested && service.registerCount == 1, "Enabling startup registers the main app and reflects actual macOS status")
        let reopened = StartupPreferences(service: service)
        try IntegrationTests.expect(reopened.isEnabled && service.registerCount == 1, "Reopening settings reads an existing OS registration without rewriting it")
        await settings.setEnabled(true)
        try IntegrationTests.expect(service.registerCount == 1, "Repeated enabled bindings do not duplicate login registration")
        await settings.setEnabled(false)
        try IntegrationTests.expect(!settings.isRequested && service.unregisterCount == 1, "Disabling startup unregisters the login item")
        service.nextStatus = .requiresApproval
        await settings.setEnabled(true)
        try IntegrationTests.expect(settings.isRequested && settings.needsApproval && !settings.isEnabled, "Pending system approval is distinguished from working automatic startup")
        settings.openSystemSettings()
        try IntegrationTests.expect(service.openSettingsCount == 1, "Pending approval offers the system Login Items settings")
        service.removalError = TunnelError("synthetic pending-request removal failure")
        await settings.setEnabled(false)
        try IntegrationTests.expect(settings.needsApproval && settings.isRequested && settings.error != nil, "Failure to cancel a pending request remains visible instead of being suppressed")
        service.removalError = nil
        await settings.setEnabled(false)
        try IntegrationTests.expect(!settings.isRequested, "A pending login request can be cancelled")
        service.registrationError = TunnelError("synthetic registration failure")
        await settings.setEnabled(true)
        try IntegrationTests.expect(!settings.isRequested && settings.error != nil && !settings.isUpdating, "Registration failure stays disabled and reports an actionable error")
        service.registrationError = nil; service.nextStatus = .enabled
        await settings.setEnabled(true)
        service.removalError = TunnelError("synthetic removal failure")
        await settings.setEnabled(false)
        try IntegrationTests.expect(settings.isEnabled && settings.error != nil, "Failed removal cannot falsely claim startup was disabled")
        service.removalError = nil
        service.status = .notRegistered; settings.refresh()
        try IntegrationTests.expect(!settings.isRequested && settings.error == nil, "External Login Items changes refresh without a stale local preference")
        service.status = .enabled; settings.refresh(); service.delayedRemoval = true
        let operation = Task { await settings.setEnabled(false) }
        try await IntegrationTests.wait("Login-item removal exposes a busy state") { settings.isUpdating }
        let registrations = service.registerCount
        await settings.setEnabled(true)
        await operation.value
        try IntegrationTests.expect(!settings.isRequested && service.registerCount == registrations && !settings.isUpdating, "Concurrent setting changes cannot race a pending login-item removal")
    }
}

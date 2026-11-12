import SwiftUI
import AppKit

struct AppearanceSettingsView: View {
    @ObservedObject var visibility: VisibilityPreferences
    @ObservedObject var startup: StartupPreferences
    var body: some View {
        Form {
            Section {
                Toggle("Dock'ta göster", isOn: Binding(get: { visibility.showDock }, set: visibility.setShowDock))
                Toggle("Menü çubuğunda (tray) göster", isOn: Binding(get: { visibility.showMenuBar }, set: visibility.setShowMenuBar))
            } header: { Text("Uygulama simgesi") } footer: {
                Text("Değişiklikler hemen uygulanır ve sonraki açılışta hatırlanır. Uygulamaya ulaşabilmek için simgelerden en az biri açık kalır; gerekirse diğeri otomatik açılır.")
            }
            Section {
                HStack {
                    Toggle("Mac açıldığında otomatik başlat", isOn: Binding(get: { startup.isRequested }, set: { enabled in Task { await startup.setEnabled(enabled) } }))
                        .disabled(startup.isUpdating)
                    if startup.isUpdating { ProgressView().controlSize(.small) }
                }
                if startup.needsApproval {
                    Label("macOS onayı bekleniyor", systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(.callout)
                    Button("Sistem Ayarları'nda izin ver…") { startup.openSystemSettings() }
                } else if startup.isEnabled {
                    Label("Oturum açıldığında otomatik başlatılacak", systemImage: "checkmark.circle").foregroundStyle(.secondary).font(.caption)
                } else if startup.status == .notFound {
                    Text("Başlangıç kaydı okunamadı. Uygulamayı Uygulamalar klasöründen açıp tekrar dene.").foregroundStyle(.secondary).font(.caption)
                }
                if let error = startup.error { Text(error).foregroundStyle(.red).font(.callout) }
            } header: { Text("Başlangıç") } footer: {
                Text("Bu Mac'te oturum açıldığında TunnelDesk'i başlatır. Otomatik açılacak tünelleri her bağlantının ayarından seçebilirsin.")
            }
            Section {
                Text("Pencereyi kapatsan da tüneller çalışmaya devam eder. Menü çubuğundaki simgeden tek tek veya topluca açıp kapatabilir, ana pencereyi yeniden açabilirsin.").foregroundStyle(.secondary)
            }
            if let error = visibility.error { Text(error).foregroundStyle(.red).font(.callout) }
        }.formStyle(.grouped).padding(12).frame(width: 470, height: 400)
            .onAppear { startup.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in startup.refresh() }
    }
}

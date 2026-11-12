import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject var visibility: VisibilityPreferences
    var body: some View {
        Form {
            Section {
                Toggle("Dock'ta göster", isOn: Binding(get: { visibility.showDock }, set: visibility.setShowDock))
                Toggle("Menü çubuğunda (tray) göster", isOn: Binding(get: { visibility.showMenuBar }, set: visibility.setShowMenuBar))
            } header: { Text("Uygulama simgesi") } footer: {
                Text("Değişiklikler hemen uygulanır ve sonraki açılışta hatırlanır. Uygulamaya ulaşabilmek için simgelerden en az biri açık kalır; gerekirse diğeri otomatik açılır.")
            }
            Section {
                Text("Pencereyi kapatsan da tüneller çalışmaya devam eder. Menü çubuğundaki simgeden tek tek veya topluca açıp kapatabilir, ana pencereyi yeniden açabilirsin.").foregroundStyle(.secondary)
            }
            if let error = visibility.error { Text(error).foregroundStyle(.red).font(.callout) }
        }.formStyle(.grouped).padding(12).frame(width: 470, height: 290)
    }
}

import SwiftUI
import AppKit

struct TunnelEditor: View {
    @ObservedObject var engine: TunnelEngine
    @Environment(\.dismiss) private var dismiss
    @State var profile: TunnelProfile
    @State private var error: String?
    @State private var contexts: [String] = []
    @State private var namespaces: [String] = []
    @State private var loading = false
    @State private var lookup: Task<Void, Never>?
    @State private var saving = false
    @State private var saveOperation: Task<Void, Never>?

    private var isNew: Bool { !engine.profiles.contains { $0.id == profile.id } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: profile.kind.symbol).font(.title2).foregroundStyle(.teal).frame(width: 38, height: 38).background(Color.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(isNew ? "Yeni tünel" : "Tüneli düzenle").font(.title3).fontWeight(.semibold)
                    Text("Bağlantı bilgilerini bir kez kaydet, her zaman kullan.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(22)
            Divider()
            Form {
                Section {
                    TextField("Tünel adı", text: $profile.name, prompt: Text("Bağlantına bir ad ver"))
                    Picker("Bağlantı türü", selection: $profile.kind) { ForEach(TunnelKind.allCases) { Text($0.title).tag($0) } }
                    TextField("Yerel port", text: $profile.localPort, prompt: Text("Bilgisayarında kullanılacak port"))
                } header: { Text("Genel") } footer: { Text("Bağlantı adresin 127.0.0.1:<yerel port> olacak. Her açık tünel farklı bir yerel port kullanmalı.") }
                if profile.kind != .ssh { kubernetesFields }
                else { sshFields }
                Section {
                    if profile.kind == .kubernetes {
                        TextField("Kaynak", text: $profile.resource, prompt: Text("pod/ad, svc/ad veya deployment/ad"))
                    } else {
                        TextField("Hedef sunucu", text: $profile.remoteHost, prompt: Text(profile.kind == .ssh ? "SSH sunucusunun erişebildiği IP / hostname" : "Cluster'ın erişebildiği IP / hostname"))
                    }
                    TextField("Hedef port", text: $profile.remotePort, prompt: Text("Bağlanılacak servisin portu"))
                } header: { Text("Hedef") } footer: {
                    Text(profile.kind == .relay ? "Cluster'da geçici bir TCP podu açılır. Tüneli kapatınca uygulamanın oluşturduğu pod temizlenir." : profile.kind == .ssh ? "SSH agent veya anahtar dosyası kullanılır. Şifre soran etkileşimli bağlantılar desteklenmez." : "Var olan pod, service veya deployment üzerinden port yönlendirilir.")
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) } }
            }.formStyle(.grouped).scrollContentBackground(.hidden).disabled(saving)
            Divider()
            HStack {
                if loading || saving { ProgressView().controlSize(.small); Text(saving ? "Kubeconfig içeri aktarılıyor…" : "Bilgiler okunuyor…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Vazgeç") { saveOperation?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Kaydet") { save() }.buttonStyle(.borderedProminent).tint(.teal).keyboardShortcut(.defaultAction).disabled(saving || engine.importingConfigs)
            }.padding(18)
        }.frame(width: 620, height: 740)
            .onDisappear { lookup?.cancel(); saveOperation?.cancel() }
            .onChange(of: profile.kubeconfig) { contexts = []; namespaces = []; lookup?.cancel(); loading = false }
            .onChange(of: profile.context) { namespaces = []; lookup?.cancel(); loading = false }
    }
    private var kubernetesFields: some View {
        Section {
            HStack {
                TextField("Kubeconfig", text: $profile.kubeconfig, prompt: Text("Dosya yolu"))
                Button("Seç…") { pickFile { profile.kubeconfig = $0 } }
            }
            HStack {
                TextField("Context", text: $profile.context, prompt: Text("Boşsa dosyanın mevcut context'i kullanılır"))
                if !contexts.isEmpty {
                    Menu { ForEach(contexts, id: \.self) { context in Button(context) { profile.context = context } } } label: { Image(systemName: "chevron.down") }.fixedSize()
                }
                Button { fetchContexts() } label: { Image(systemName: "arrow.clockwise") }.help("Context'leri dosyadan oku").disabled(profile.kubeconfig.isEmpty || loading)
            }
            HStack {
                TextField("Namespace", text: $profile.namespace, prompt: Text("Uygulamanın namespace'i"))
                if !namespaces.isEmpty {
                    Menu { ForEach(namespaces, id: \.self) { namespace in Button(namespace) { profile.namespace = namespace } } } label: { Image(systemName: "chevron.down") }.fixedSize()
                }
                Button { fetchNamespaces() } label: { Image(systemName: "arrow.clockwise") }.help("Erişilebilir namespace'leri oku").disabled(profile.kubeconfig.isEmpty || loading)
            }
        } header: { Text("Kubernetes") } footer: { Text("Kaydettiğinde kubeconfig uygulamaya kopyalanır; orijinal dosyayı silebilirsin. Güncellemek için yeni dosya seçip tekrar kaydet. Context ve namespace listelerini oklarla yükleyebilirsin.") }
    }
    private var sshFields: some View {
        Section {
            TextField("SSH sunucusu", text: $profile.sshHost, prompt: Text("IP, hostname veya SSH config takma adı"))
            TextField("SSH kullanıcısı", text: $profile.sshUser, prompt: Text("Boşsa SSH config / mevcut kullanıcı"))
            TextField("SSH portu", text: $profile.sshPort)
            HStack {
                TextField("Anahtar dosyası", text: $profile.identityFile, prompt: Text("İsteğe bağlı; boşsa SSH agent / config"))
                Button("Seç…") { pickFile { profile.identityFile = $0 } }
            }
        } header: { Text("SSH bağlantısı") }
    }
    private func pickFile(onPick: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true; panel.prompt = "Seç"
        if panel.runModal() == .OK, let url = panel.url { onPick(url.path) }
    }
    private func fetchContexts() {
        error = nil; loading = true; let path = profile.kubeconfig
        lookup = Task { @MainActor in
            defer { loading = false }
            do {
                let result = try await engine.loadContexts(kubeconfig: path)
                try Task.checkCancellation()
                contexts = result
                if result.isEmpty { error = "Dosyada context bulunamadı." }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    private func fetchNamespaces() {
        error = nil; loading = true; let snapshot = profile
        lookup = Task { @MainActor in
            defer { loading = false }
            do {
                let result = try await engine.loadNamespaces(profile: snapshot)
                try Task.checkCancellation()
                namespaces = result
                if result.isEmpty { error = "Erişilebilir namespace bulunamadı; elle yazabilirsin." }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    private func save() {
        saving = true; error = nil; let snapshot = profile
        saveOperation = Task { @MainActor in
            defer { saving = false }
            do { try await engine.save(snapshot); dismiss() }
            catch is CancellationError {}
            catch { self.error = error.localizedDescription }
        }
    }
}

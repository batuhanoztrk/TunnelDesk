import SwiftUI
import AppKit

extension TunnelStatus {
    var color: Color {
        switch self { case .running: return .green; case .failed: return .red; case .preparing, .starting, .stopping: return .orange; case .stopped: return .secondary }
    }
}

struct EditorPresentation: Identifiable {
    let id = UUID()
    var profile: TunnelProfile
}

struct MainView: View {
    @EnvironmentObject var engine: TunnelEngine
    @State private var editor: EditorPresentation?
    @State private var search = ""
    @State private var deleteCandidate: TunnelProfile?
    private var filtered: [TunnelProfile] {
        engine.profiles.filter { search.isEmpty || ($0.name + " " + $0.destination + " " + $0.kind.shortTitle).localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.title2).foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("TunnelDesk").font(.headline)
                        Text(engine.importingConfigs ? "Kubeconfig içeri aktarılıyor…" : "\(engine.runningCount) açık · \(engine.profiles.count) tünel").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(18)
                Divider()
                List(selection: $engine.selectedID) {
                    Section("Tüneller") {
                        ForEach(filtered) { profile in
                            TunnelRow(profile: profile, session: engine.session(for: profile.id)).tag(profile.id)
                                .contextMenu {
                                    Button("Aç") { engine.start(profile) }.disabled(engine.session(for: profile.id).status.busy)
                                    Button("Kapat") { engine.stop(profile) }.disabled(!engine.session(for: profile.id).status.busy)
                                    Divider()
                                    Button("Düzenle") { editor = EditorPresentation(profile: profile) }.disabled(engine.session(for: profile.id).status.busy || engine.session(for: profile.id).relayName != nil)
                                    Button("Çoğalt") { duplicate(profile) }
                                    Button("Sil", role: .destructive) { deleteCandidate = profile }.disabled(engine.session(for: profile.id).status.busy)
                                }
                        }
                    }
                }.listStyle(.sidebar).searchable(text: $search, prompt: "Tünel ara")
                Divider()
                HStack {
                    Button { editor = EditorPresentation(profile: TunnelProfile()) } label: { Label("Yeni tünel", systemImage: "plus") }.buttonStyle(.plain)
                    Spacer()
                    Image(systemName: "lock.shield").foregroundStyle(.secondary).help("Yerel tüneller yalnızca 127.0.0.1 üzerinde dinler.")
                }.font(.callout).padding(16)
            }.navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 330)
        } detail: {
            if let profile = engine.selected {
                TunnelDetail(profile: profile, session: engine.session(for: profile.id), onEdit: { editor = EditorPresentation(profile: profile) }, onDuplicate: { duplicate(profile) }, onDelete: { deleteCandidate = profile })
            } else {
                EmptyTunnelView(hasProfiles: !engine.profiles.isEmpty) { editor = EditorPresentation(profile: TunnelProfile()) }
            }
        }
        .navigationTitle("TunnelDesk")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { engine.startAll() } label: { Label("Tümünü aç", systemImage: "play.fill") }.disabled(engine.profiles.isEmpty || engine.shuttingDown || engine.importingConfigs).help("Kayıtlı tünelleri aynı anda aç")
                Button { engine.stopAll() } label: { Label("Tümünü kapat", systemImage: "stop.fill") }.disabled(engine.activeCount == 0).help("Açık tünelleri ve geçici podlarını kapat")
                Divider()
                Button { editor = EditorPresentation(profile: TunnelProfile()) } label: { Label("Yeni tünel", systemImage: "plus") }.keyboardShortcut("n")
            }
        }
        .sheet(item: $editor) { presentation in TunnelEditor(engine: engine, profile: presentation.profile) }
        .alert("Tünel silinsin mi?", isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } })) {
            Button("Vazgeç", role: .cancel) { deleteCandidate = nil }
            Button("Sil", role: .destructive) { if let profile = deleteCandidate { engine.remove(profile) }; deleteCandidate = nil }
        } message: { Text("“\(deleteCandidate?.name ?? "")” kaydı silinecek.") }
        .alert("TunnelDesk", isPresented: Binding(get: { engine.notice != nil }, set: { if !$0 { engine.notice = nil } })) {
            Button("Tamam") { engine.notice = nil }
        } message: { Text(engine.notice ?? "") }
        .frame(minWidth: 890, minHeight: 630)
    }
    private func duplicate(_ profile: TunnelProfile) {
        var copy = profile; copy.id = UUID(); copy.name += " kopyası"; copy.localPort = ""
        editor = EditorPresentation(profile: copy)
    }
}

struct TunnelRow: View {
    let profile: TunnelProfile
    @ObservedObject var session: TunnelSession
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: profile.kind.symbol).font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name).fontWeight(.medium).lineLimit(1)
                Text(":\(profile.localPort) · \(profile.kind.shortTitle)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 5)
            Circle().fill(session.status.color).frame(width: 7, height: 7).help(session.status.title)
        }.padding(.vertical, 7)
    }
}

struct EmptyTunnelView: View {
    var hasProfiles: Bool
    var onAdd: () -> Void
    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 26).fill(Color.teal.opacity(0.09)).frame(width: 104, height: 104)
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 47, weight: .light)).foregroundStyle(.teal)
            }
            VStack(spacing: 10) {
                Text(hasProfiles ? "Bir tünel seç" : "Tünellerin tek bir yerde.").font(.system(size: 27, weight: .semibold, design: .rounded))
                Text(hasProfiles ? "Bağlantı ayrıntılarını ve günlüğünü buradan yönet." : "Bağlantılarını kaydet. İhtiyacın olduğunda birlikte aç,\nişin bittiğinde tek tıkla kapat.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4)
            }
            HStack(spacing: 10) {
                ForEach(["Kubernetes TCP", "Port yönlendirme", "SSH"], id: \.self) { title in
                    Text(title).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 11).padding(.vertical, 6).background(.quaternary, in: Capsule())
                }
            }
            Button(action: onAdd) { Label("İlk tünelini ekle", systemImage: "plus") }.buttonStyle(.borderedProminent).tint(.teal).controlSize(.large).padding(.top, 3)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor))
    }
}

struct TunnelDetail: View {
    @EnvironmentObject var engine: TunnelEngine
    let profile: TunnelProfile
    @ObservedObject var session: TunnelSession
    var onEdit: () -> Void
    var onDuplicate: () -> Void
    var onDelete: () -> Void
    @State private var copied = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                HStack(alignment: .top, spacing: 12) {
                    MetricCard(title: "YEREL ADRES", value: profile.endpoint, symbol: "desktopcomputer")
                    MetricCard(title: "HEDEF", value: profile.kind == .kubernetes ? profile.resource : "\(profile.remoteHost):\(profile.remotePort)", symbol: "server.rack")
                }
                connectionInfo
                if let error = session.error {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("Bağlantı tamamlanamadı", systemImage: "exclamationmark.triangle.fill").fontWeight(.medium)
                        Text(error).font(.callout).textSelection(.enabled)
                        if session.relayName != nil { Button("Podu temizle") { engine.stop(profile) } }
                    }.foregroundStyle(.red).padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.red.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
                }
                logView
            }.padding(30).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
        }.background(Color(nsColor: .textBackgroundColor))
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(profile.kind.shortTitle, systemImage: profile.kind.symbol).font(.callout).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 6) {
                    if [.preparing, .starting, .stopping].contains(session.status) { ProgressView().controlSize(.mini) }
                    else { Circle().fill(session.status.color).frame(width: 7, height: 7) }
                    Text(session.status.title).font(.callout).foregroundStyle(session.status.color)
                }.padding(.horizontal, 10).padding(.vertical, 5).background(session.status.color.opacity(0.08), in: Capsule())
            }
            Text(profile.name).font(.system(size: 29, weight: .semibold, design: .rounded)).textSelection(.enabled)
            HStack(spacing: 10) {
                if session.status.busy {
                    Button { engine.stop(profile) } label: { Label("Tüneli kapat", systemImage: "stop.fill") }.buttonStyle(.borderedProminent).tint(.orange).disabled(session.status == .stopping)
                } else {
                    Button { engine.start(profile) } label: { Label("Tüneli aç", systemImage: "play.fill") }.buttonStyle(.borderedProminent).tint(.teal).disabled(engine.importingConfigs)
                }
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(profile.endpoint, forType: .string); copied = true; DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false } } label: { Label(copied ? "Kopyalandı" : "Adresi kopyala", systemImage: copied ? "checkmark" : "doc.on.doc") }
                Spacer()
                Button(action: onEdit) { Image(systemName: "slider.horizontal.3") }.help("Düzenle").disabled(session.status.busy || session.relayName != nil)
                Menu { Button("Çoğalt", action: onDuplicate); Divider(); Button("Sil", role: .destructive, action: onDelete).disabled(session.status.busy || session.relayName != nil) } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
            }.controlSize(.large)
        }
    }
    private var connectionInfo: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bağlantı ayrıntıları").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 26, verticalSpacing: 10) {
                if profile.kind == .ssh {
                    infoRow("SSH sunucusu", profile.sshHost)
                    infoRow("SSH kullanıcısı", profile.sshUser.isEmpty ? "SSH config / mevcut kullanıcı" : profile.sshUser)
                    infoRow("SSH portu", profile.sshPort)
                    if !profile.identityFile.isEmpty { infoRow("Anahtar dosyası", profile.identityFile) }
                } else {
                    infoRow("Kubeconfig", profile.kubeconfig)
                    infoRow("Context", profile.context.isEmpty ? "Kubeconfig'in mevcut context'i" : profile.context)
                    infoRow("Namespace", profile.namespace)
                }
                infoRow("Hedef port", profile.remotePort)
                if let date = session.startedAt { infoRow("Açılma zamanı", date.formatted(date: .omitted, time: .standard)) }
            }.font(.callout)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
    }
    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).lineLimit(3)
        }
    }
    private var logView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Bağlantı günlüğü").font(.headline)
                Spacer()
                Button("Temizle") { session.log = "" }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(session.log.isEmpty ? "Tüneli açtığında bağlantı adımları burada görünecek." : session.log)
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(session.log.isEmpty ? Color.secondary : Color.primary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(15)
                }.frame(height: 195).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    .onChange(of: session.log) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}

struct MetricCard: View {
    var title: String
    var value: String
    var symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17, weight: .medium, design: .monospaced)).textSelection(.enabled).lineLimit(2)
        }.padding(18).frame(maxWidth: .infinity, minHeight: 65, alignment: .topLeading).background(Color.teal.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
    }
}

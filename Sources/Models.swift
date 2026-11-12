import Foundation
import Darwin

enum TunnelKind: String, Codable, CaseIterable, Identifiable {
    case relay, kubernetes, ssh
    var id: String { rawValue }
    var title: String {
        switch self {
        case .relay: return "Kubernetes · TCP tüneli"
        case .kubernetes: return "Kubernetes · Port yönlendirme"
        case .ssh: return "SSH · Yerel tünel"
        }
    }
    var shortTitle: String {
        switch self { case .relay: return "Kubernetes TCP"; case .kubernetes: return "Kubernetes"; case .ssh: return "SSH" }
    }
    var symbol: String {
        switch self { case .relay: return "arrow.triangle.branch"; case .kubernetes: return "shippingbox"; case .ssh: return "terminal" }
    }
}

struct TunnelProfile: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""
    var kind: TunnelKind = .relay
    var localPort = ""
    var kubeconfig = ""
    var context = ""
    var namespace = ""
    var resource = ""
    var remoteHost = ""
    var remotePort = ""
    var sshHost = ""
    var sshUser = ""
    var sshPort = "22"
    var identityFile = ""

    var endpoint: String { "127.0.0.1:\(localPort)" }
    var destination: String {
        kind == .kubernetes ? "\(namespace) / \(resource):\(remotePort)" : "\(remoteHost):\(remotePort)"
    }
    var relayPrefix: String { "tunneldesk-" + id.uuidString.lowercased().prefix(8) }
    func normalized() -> Self {
        var p = self
        p.name = p.name.trimmed; p.localPort = p.localPort.trimmed
        p.kubeconfig = p.kubeconfig.trimmed; p.context = p.context.trimmed
        p.namespace = p.namespace.trimmed; p.resource = p.resource.trimmed
        p.remoteHost = p.remoteHost.trimmed; p.remotePort = p.remotePort.trimmed
        p.sshHost = p.sshHost.trimmed; p.sshUser = p.sshUser.trimmed
        p.sshPort = p.sshPort.trimmed; p.identityFile = p.identityFile.trimmed
        return p
    }
    func validate(checkFiles: Bool = true) throws {
        guard !name.trimmed.isEmpty else { throw TunnelError("Tünel için bir ad yaz.") }
        guard Self.port(localPort) != nil else { throw TunnelError("Yerel port 1–65535 arasında olmalı.") }
        guard Self.port(remotePort) != nil else { throw TunnelError("Hedef port 1–65535 arasında olmalı.") }
        if kind != .ssh {
            guard !kubeconfig.isEmpty else { throw TunnelError("Bir kubeconfig dosyası seç.") }
            if checkFiles && !FileManager.default.isReadableFile(atPath: kubeconfig.expandingTilde) {
                throw TunnelError("Kubeconfig dosyası okunamıyor. Dosyayı yeniden seç.")
            }
            guard namespace.matches("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$") else {
                throw TunnelError("Geçerli bir namespace yaz.")
            }
            if kind == .kubernetes {
                guard resource.matches("^(pod|pods|service|services|svc|deployment|deployments|deploy)/[a-z0-9]([a-z0-9.-]*[a-z0-9])?$") else {
                    throw TunnelError("Kaynağı pod/ad, svc/ad veya deployment/ad biçiminde yaz.")
                }
            }
        } else {
            guard Self.validHost(sshHost) else { throw TunnelError("Geçerli bir SSH sunucusu veya SSH config takma adı yaz.") }
            guard sshUser.isEmpty || sshUser.matches("^[A-Za-z0-9_][A-Za-z0-9_.-]*$") else { throw TunnelError("SSH kullanıcı adı geçersiz.") }
            guard Self.port(sshPort) != nil else { throw TunnelError("SSH portu 1–65535 arasında olmalı.") }
            if checkFiles && !identityFile.isEmpty && !FileManager.default.isReadableFile(atPath: identityFile.expandingTilde) {
                throw TunnelError("SSH anahtar dosyası okunamıyor.")
            }
        }
        if kind != .kubernetes && !Self.validHost(remoteHost) { throw TunnelError("Geçerli bir hedef sunucu adresi yaz.") }
    }
    static func port(_ value: String) -> UInt16? {
        guard value.matches("^[0-9]+$"), let port = UInt16(value), port > 0 else { return nil }
        return port
    }
    static func validHost(_ host: String) -> Bool {
        !host.isEmpty && !host.hasPrefix("-") && host.matches("^[A-Za-z0-9_][A-Za-z0-9_.:-]*$")
    }
    func kubectlArguments(_ tail: [String], timed: Bool = true) -> [String] {
        var args = ["--kubeconfig", kubeconfig.expandingTilde]
        if !context.isEmpty { args += ["--context", context] }
        if !namespace.isEmpty { args += ["--namespace", namespace] }
        if timed { args += ["--request-timeout=20s"] }
        return args + tail
    }
    func forwardArguments(relayName: String? = nil) -> [String] {
        if kind != .ssh {
            let target = kind == .relay ? "pod/\(relayName ?? relayPrefix)" : resource
            return kubectlArguments(["port-forward", "--address=127.0.0.1", target, "\(localPort):\(kind == .relay ? "1433" : remotePort)"], timed: false)
        }
        let host = remoteHost.contains(":") ? "[\(remoteHost)]" : remoteHost
        var args = ["-N", "-T", "-v", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ControlPersist=no", "-o", "ForkAfterAuthentication=no", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-L", "127.0.0.1:\(localPort):\(host):\(remotePort)", "-p", sshPort]
        if !identityFile.isEmpty { args += ["-i", identityFile.expandingTilde] }
        args += ["--", sshUser.isEmpty ? sshHost : "\(sshUser)@\(sshHost)"]
        return args
    }
    func relayManifest(name: String) throws -> Data {
        let target = remoteHost.contains(":") ? "[\(remoteHost)]" : remoteHost
        let object: [String: Any] = [
            "apiVersion": "v1", "kind": "Pod",
            "metadata": ["name": name, "namespace": namespace, "labels": ["app.kubernetes.io/managed-by": "tunneldesk", "tunneldesk-profile": id.uuidString.lowercased()]],
            "spec": [
                "automountServiceAccountToken": false, "restartPolicy": "Never", "activeDeadlineSeconds": 86400, "terminationGracePeriodSeconds": 2,
                "securityContext": ["runAsNonRoot": true, "runAsUser": 65534, "runAsGroup": 65534, "seccompProfile": ["type": "RuntimeDefault"]],
                "containers": [["name": "relay", "image": "alpine/socat:latest", "command": ["socat"],
                                "args": ["TCP-LISTEN:1433,bind=127.0.0.1,fork,reuseaddr", "TCP:\(target):\(remotePort),connect-timeout=10"],
                                "resources": ["requests": ["cpu": "5m", "memory": "8Mi"], "limits": ["cpu": "100m", "memory": "32Mi"]],
                                "securityContext": ["allowPrivilegeEscalation": false, "readOnlyRootFilesystem": true, "capabilities": ["drop": ["ALL"]]]]]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    func cleanupArguments(name: String) -> [String] {
        kubectlArguments(["delete", "pods", "--selector=app.kubernetes.io/managed-by=tunneldesk,tunneldesk-profile=\(id.uuidString.lowercased())", "--field-selector=metadata.name=\(name)", "--ignore-not-found=true", "--wait=false"])
    }
}

struct TunnelError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var expandingTilde: String { (self as NSString).expandingTildeInPath }
    func matches(_ pattern: String) -> Bool { range(of: pattern, options: .regularExpression) != nil }
}

enum TunnelStatus: String {
    case stopped, preparing, starting, running, stopping, failed
    var title: String {
        switch self {
        case .stopped: return "Kapalı"; case .preparing: return "Hazırlanıyor"; case .starting: return "Bağlanıyor"
        case .running: return "Açık"; case .stopping: return "Kapatılıyor"; case .failed: return "Hata"
        }
    }
    var busy: Bool { [.preparing, .starting, .running, .stopping].contains(self) }
}

enum LocalPort {
    static func ensureAvailable(_ port: UInt16) throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TunnelError("Yerel port kontrol edilemedi.") }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw TunnelError("127.0.0.1:\(port) başka bir işlem tarafından kullanılıyor. O tüneli kapat veya farklı bir yerel port seç.") }
    }
}

struct ToolPaths {
    var kubectl: String?
    var ssh: String?
    static var detected: Self {
        Self(kubectl: find("kubectl"), ssh: find("ssh"))
    }
    static func find(_ name: String) -> String? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        return paths.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

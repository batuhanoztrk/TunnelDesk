import Foundation

/// Private, self-contained kubeconfig snapshots. Never logs credential-bearing output.
final class KubeconfigStore {
    let directory: URL
    init(profileStore: ProfileStore) {
        directory = profileStore.url.deletingLastPathComponent().appendingPathComponent("kubeconfigs", isDirectory: true).standardizedFileURL
    }
    func isManaged(_ path: String, for profileID: UUID? = nil) -> Bool {
        let file = URL(fileURLWithPath: path.expandingTilde).standardizedFileURL
        guard file.deletingLastPathComponent() == directory,
              file.lastPathComponent.matches("^[a-f0-9-]{36}--[a-f0-9-]{36}\\.json$"),
              (try? FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType) == .typeRegular else { return false }
        return profileID.map { file.lastPathComponent.hasPrefix($0.uuidString.lowercased() + "--") } ?? true
    }
    func importFile(_ source: String, for profileID: UUID, kubectl: String?) async throws -> String {
        let file = URL(fileURLWithPath: source.expandingTilde).standardizedFileURL
        guard FileManager.default.isReadableFile(atPath: file.path) else {
            throw TunnelError("Kubeconfig dosyası okunamıyor. Dosyayı yeniden seçip kaydet.")
        }
        if isManaged(file.path, for: profileID) { return file.path }
        let data: Data
        if isManaged(file.path) {
            data = try Data(contentsOf: file)
        } else {
            guard let kubectl else { throw TunnelError("Kubeconfig'i içeri aktarmak için kubectl gerekli. kubectl kurup uygulamayı yeniden aç.") }
            let result = try await CommandExecutor.run(kubectl, ["--kubeconfig", file.path, "config", "view", "--flatten", "--raw", "-o", "json"], timeout: 20, captureLimit: nil, discardStderr: true)
            guard result.code == 0 else { throw TunnelError("Kubeconfig içeri aktarılamadı. Dosyanın geçerliliğini ve içindeki sertifika / anahtar yollarını kontrol et.") }
            data = Data(result.output.utf8)
        }
        var config: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let clusters = object["clusters"] as? [Any], !clusters.isEmpty,
                  let contexts = object["contexts"] as? [Any], !contexts.isEmpty else { throw TunnelError("invalid") }
            config = object
        } catch { throw TunnelError("Kubeconfig içeri aktarılamadı. Dosyada en az bir cluster ve context bulunmalı.") }
        // kubectl --flatten embeds certificates and keys but not tokenFile credentials.
        if var users = config["users"] as? [[String: Any]] {
            for index in users.indices {
                guard var user = users[index]["user"] as? [String: Any] else { continue }
                if var exec = user["exec"] as? [String: Any], let command = exec["command"] as? String,
                   command.contains("/"), !command.hasPrefix("/") {
                    exec["command"] = file.deletingLastPathComponent().appendingPathComponent(command).standardizedFileURL.path
                    user["exec"] = exec
                }
                if let tokenFile = user["tokenFile"] as? String, !tokenFile.isEmpty {
                    let path = tokenFile.hasPrefix("/") ? URL(fileURLWithPath: tokenFile) : file.deletingLastPathComponent().appendingPathComponent(tokenFile)
                    guard let token = try? String(contentsOf: path, encoding: .utf8).trimmed, !token.isEmpty else {
                        throw TunnelError("Kubeconfig'in başvurduğu token dosyası okunamıyor.")
                    }
                    user["token"] = token; user.removeValue(forKey: "tokenFile")
                }
                users[index]["user"] = user
            }
            config["users"] = users
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let destination = directory.appendingPathComponent(profileID.uuidString.lowercased() + "--" + UUID().uuidString.lowercased() + ".json")
        do {
            // kubectl's YAML decoder does not accept JSON's optional escaped slash (\/).
            try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw TunnelError("Kubeconfig uygulamanın veri klasörüne kaydedilemedi. Disk alanını ve klasör izinlerini kontrol et.")
        }
        return destination.path
    }
    func removeIfUnused(_ path: String, profiles: [TunnelProfile]) throws {
        guard isManaged(path), !profiles.contains(where: { $0.kubeconfig == path }) else { return }
        try FileManager.default.removeItem(atPath: path)
    }
}

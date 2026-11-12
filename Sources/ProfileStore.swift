import Foundation

final class ProfileStore {
    let url: URL
    init(url: URL? = nil) {
        if let url { self.url = url; return }
        if let override = ProcessInfo.processInfo.environment["TUNNELDESK_PROFILE_PATH"] {
            self.url = URL(fileURLWithPath: override); return
        }
        self.url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TunnelDesk", isDirectory: true).appendingPathComponent("profiles.json")
    }
    func load() throws -> [TunnelProfile] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let profiles = try JSONDecoder().decode([TunnelProfile].self, from: Data(contentsOf: url))
        guard Set(profiles.map(\.id)).count == profiles.count else { throw TunnelError("Kayıt dosyasında aynı kimliğe sahip birden fazla tünel var.") }
        return profiles
    }
    func save(_ profiles: [TunnelProfile]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

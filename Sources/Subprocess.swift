import Foundation
import Darwin

struct CommandResult {
    let code: Int32
    let output: String
    func checked() throws -> Self {
        guard code == 0 else { throw TunnelError(output.trimmed.isEmpty ? "Komut başarısız oldu (\(code))." : output.trimmed) }
        return self
    }
}

/// One owned child process. Arguments never pass through a shell.
final class Subprocess: @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var active: [ObjectIdentifier: Subprocess] = [:]
    let process = Process()
    private let pipe = Pipe()
    private let lock = NSLock()
    private let readLock = NSLock()
    private var buffer = Data()
    private var cancelled = false
    private var finished = false
    private let captureLimit: Int?
    var onOutput: ((String) -> Void)?
    var onExit: ((CommandResult) -> Void)?

    private static func register(_ command: Subprocess) {
        registryLock.lock(); defer { registryLock.unlock() }
        active[ObjectIdentifier(command)] = command
    }
    private static func unregister(_ command: Subprocess) {
        registryLock.lock(); defer { registryLock.unlock() }
        active.removeValue(forKey: ObjectIdentifier(command))
    }
    private static func snapshot() -> [Subprocess] {
        registryLock.lock(); defer { registryLock.unlock() }
        return Array(active.values)
    }
    static func stopAllOwnedCommands() async {
        let commands = snapshot()
        commands.forEach { $0.stop() }
        for _ in 0..<160 {
            if commands.allSatisfy({ !$0.process.isRunning }) { return }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    init(executable: String, arguments: [String], captureLimit: Int? = 262_144, discardStderr: Bool = false) {
        self.captureLimit = captureLimit
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = discardStderr ? FileHandle.nullDevice : pipe
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (environment["PATH"] ?? "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin"
        // No password or GUI askpass prompts may outlive a tunnel.
        environment["SSH_ASKPASS_REQUIRE"] = "never"
        process.environment = environment
    }
    func start(input: Data? = nil) throws {
        lock.lock()
        guard !cancelled else { lock.unlock(); throw CancellationError() }
        let inputPipe = input == nil ? nil : Pipe()
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        pipe.fileHandleForReading.readabilityHandler = { [weak self] _ in self?.drain() }
        process.terminationHandler = { [weak self] process in self?.finish(code: process.terminationStatus) }
        Self.register(self)
        do { try process.run(); lock.unlock() }
        catch {
            lock.unlock()
            pipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            Self.unregister(self)
            throw error
        }
        if let input, let inputPipe {
            DispatchQueue.global(qos: .utility).async {
                do { try inputPipe.fileHandleForWriting.write(contentsOf: input) } catch { /* process may have exited */ }
                try? inputPipe.fileHandleForWriting.close()
            }
        }
    }
    private func drain() {
        readLock.lock(); defer { readLock.unlock() }
        var bytes = [UInt8](repeating: 0, count: 4096)
        // A bounded, nonblocking drain also handles inherited pipe writers on cancellation.
        for _ in 0..<64 {
            let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            if count > 0 { receive(Data(bytes.prefix(count))) }
            else {
                if count == 0 { pipe.fileHandleForReading.readabilityHandler = nil }
                break
            }
        }
    }
    private func receive(_ data: Data) {
        lock.lock()
        buffer.append(data)
        if let captureLimit, buffer.count > captureLimit { buffer.removeFirst(buffer.count - captureLimit) }
        lock.unlock()
        onOutput?(String(decoding: data, as: UTF8.self))
    }
    private func finish(code: Int32) {
        pipe.fileHandleForReading.readabilityHandler = nil
        drain()
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let text = String(decoding: buffer, as: UTF8.self)
        lock.unlock()
        onExit?(CommandResult(code: code, output: text))
        onOutput = nil
        onExit = nil
        Self.unregister(self)
    }
    func stop() {
        lock.lock()
        cancelled = true
        let running = process.isRunning
        let pid = running ? process.processIdentifier : 0
        lock.unlock()
        if running {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.process.isRunning, self.process.processIdentifier == pid else { return }
                Darwin.kill(pid, SIGKILL)
            }
        }
    }
    deinit { if process.isRunning { process.terminate() } }
}

enum CommandExecutor {
    static func run(_ executable: String, _ arguments: [String], input: Data? = nil, timeout: TimeInterval = 30, captureLimit: Int? = 262_144, discardStderr: Bool = false, onOutput: ((String) -> Void)? = nil) async throws -> CommandResult {
        let command = Subprocess(executable: executable, arguments: arguments, captureLimit: captureLimit, discardStderr: discardStderr)
        let deadline = DispatchWorkItem { command.stop() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result: CommandResult = try await withCheckedThrowingContinuation { continuation in
                command.onOutput = onOutput
                command.onExit = { result in
                    deadline.cancel()
                    continuation.resume(returning: result)
                }
                do {
                    try command.start(input: input)
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                } catch {
                    deadline.cancel()
                    continuation.resume(throwing: error)
                }
            }
            try Task.checkCancellation()
            return result
        } onCancel: { command.stop() }
    }
}

import Foundation
import Darwin

/// Owns only proposal IPC. The model has no native approve/commit endpoint.
/// File descriptors and lifecycle state are protected by lock; only the worker closes fds.
final class AgentIPCServer: @unchecked Sendable {
    let endpoint: AgentIPCEndpoint
    private let directory: URL
    private let listener: Int32
    private let bridge: AgentMCPBridge
    private let lock = NSLock()
    private var stopped = false
    private var activeSocket: Int32 = -1
    private let completed = DispatchGroup()
    init(bridge: AgentMCPBridge) throws {
        let directory = URL(fileURLWithPath: "/private/tmp/jarvis-" + UUID().uuidString, isDirectory: true)
        try PrivateAgentFiles.directory(directory)
        let path = directory.appendingPathComponent("mcp.sock").path
        let socket = try AgentSocket.create()
        do {
            guard try AgentSocket.address(path, { Darwin.bind(socket, $0, $1) }) == 0,
                  chmod(path, 0o600) == 0, Darwin.listen(socket, 4) == 0,
                  fcntl(socket, F_SETFL, O_NONBLOCK) == 0 else { throw AgentError.unavailable }
        } catch { Darwin.close(socket); try? FileManager.default.removeItem(at: directory); throw error }
        self.directory = directory; listener = socket; self.bridge = bridge
        endpoint = AgentIPCEndpoint(socketPath: path, capability: UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
        completed.enter()
        DispatchQueue.global(qos: .utility).async { self.serve() }
    }
    func stop() async {
        await bridge.close()
        requestStop()
        await withCheckedContinuation { continuation in completed.notify(queue: .global()) { continuation.resume() } }
    }
    private func requestStop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        if activeSocket >= 0 { Darwin.shutdown(activeSocket, SHUT_RDWR) }
    }
    private func isStopped() -> Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    private func serve() {
        defer {
            Darwin.close(listener)
            unlink(endpoint.socketPath)
            try? FileManager.default.removeItem(at: directory)
            completed.leave()
        }
        while !isStopped() {
            var item = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&item, 1, 200)
            if ready < 0 && errno == EINTR { continue }
            if ready < 0 { return }
            if ready == 0 { continue }
            let connection = Darwin.accept(listener, nil, nil)
            if connection < 0 { continue }
            lock.lock()
            if stopped { lock.unlock(); Darwin.close(connection); return }
            activeSocket = connection; lock.unlock()
            do { try AgentSocket.configure(connection); try AgentSocket.verifyPeer(connection); try exchange(connection) }
            catch { /* No payloads or IPC credentials in logs. */ }
            lock.lock(); activeSocket = -1; Darwin.close(connection); lock.unlock()
        }
    }
    private func exchange(_ fd: Int32) throws {
        let reader = AgentFrameReader(fd)
        while !isStopped(), let envelope = try reader.next() {
            guard case .object(let fields) = envelope, Set(fields.keys) == ["capability", "message"],
                  let token = envelope["capability"].string, authenticate(token) else { throw AgentError.invalidConfiguration }
            let message = envelope["message"]
            let semaphore = DispatchSemaphore(value: 0), reply = IPCReply()
            let task = Task { [bridge] in
                let value = await bridge.handle(message); reply.set(value); semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 5) == .success else { task.cancel(); throw AgentError.timeout }
            guard !isStopped() else { throw AgentError.closed }
            try AgentSocket.send(.object(["message": reply.get() ?? .null]), fd: fd)
        }
    }
    private func authenticate(_ token: String) -> Bool {
        let a = Array(token.utf8), b = Array(endpoint.capability.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
private final class IPCReply: @unchecked Sendable {
    private let lock = NSLock()
    private var value: JSONValue?
    func set(_ value: JSONValue?) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> JSONValue? { lock.lock(); defer { lock.unlock() }; return value }
}

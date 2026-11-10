import Foundation

/// ACP v1 newline-delimited stdio. No shell, no stdout/stderr logging, bounded frames.
actor JSONRPCProcess {
    typealias Handler = @Sendable (JSONValue) async -> Void
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var sequence = 0
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var deadlines: [String: Task<Void, Never>] = [:]
    private var handler: Handler?
    private let writer = DispatchQueue(label: "jarvis.acp.writer")
    private var closed = true
    func setHandler(_ value: @escaping Handler) { handler = value }
    func start(executable: URL, arguments: [String] = [], environment: [String: String], cwd: URL? = nil) throws {
        guard process == nil else { throw AgentError.busy }
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = executable; child.arguments = arguments
        child.environment = environment; child.currentDirectoryURL = cwd
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
        try child.run()
        process = child; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading; closed = false
        let reader = stdout.fileHandleForReading
        Task.detached { [weak self] in
            defer { try? reader.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = Darwin.read(reader.fileDescriptor, &bytes, bytes.count)
                if n < 0 && errno == EINTR { continue }
                guard n > 0, let self else { break }
                await self.ingest(Data(bytes.prefix(n)))
            }
            await self?.end(AgentError.closed)
        }
    }
    func request(_ method: String, _ params: JSONValue, timeout: TimeInterval = 30) async throws -> JSONValue {
        try Task.checkCancellation()
        guard !closed else { throw AgentError.closed }
        guard timeout > 0, timeout <= 120 else { throw AgentError.invalidConfiguration }
        sequence += 1; let id = "jarvis-\(sequence)"
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                deadlines[id] = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
                    catch { return }
                    await self?.end(AgentError.timeout)
                }
                do { try send(.object(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method), "params": params])) }
                catch { end(error) }
            }
        }, onCancel: { Task { await self.end(AgentError.cancelled) } })
    }
    func notify(_ method: String, _ params: JSONValue) throws {
        try send(.object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params]))
    }
    func respond(id: JSONValue, result: JSONValue) throws {
        try send(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }
    func reject(id: JSONValue) throws {
        try send(.object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(-32601), "message": .string("Unsupported method")])]))
    }
    private func send(_ message: JSONValue) throws {
        guard !closed, let input else { throw AgentError.closed }
        var bytes = try JSONEncoder().encode(message)
        guard bytes.count <= 262_144 else { throw AgentError.invalidMessage }
        bytes.append(0x0a)
        let payload = bytes
        writer.async { [weak self] in
            do { try input.write(contentsOf: payload) }
            catch { Task { await self?.end(AgentError.closed) } }
        }
    }
    private func ingest(_ bytes: Data) async {
        guard !closed else { return }
        buffer.append(bytes)
        while let endIndex = buffer.firstIndex(of: 0x0a) {
            let line = buffer.prefix(upTo: endIndex); buffer.removeSubrange(...endIndex)
            if line.isEmpty { continue }
            guard line.count <= 262_144, let message = try? JSONDecoder().decode(JSONValue.self, from: line),
                  message["jsonrpc"].string == "2.0" else { end(AgentError.invalidMessage); return }
            if let method = message["method"].string {
                if method.isEmpty { end(AgentError.invalidMessage); return }
                if let handler { await handler(message) }
                else if message["id"] != .null { try? reject(id: message["id"]) }
            } else if let id = message["id"].string, let continuation = pending.removeValue(forKey: id) {
                deadlines.removeValue(forKey: id)?.cancel()
                if let code = message["error"]["code"].decimal {
                    continuation.resume(throwing: AgentError.provider(NSDecimalNumber(decimal: code).intValue))
                } else if message["error"] != .null { continuation.resume(throwing: AgentError.invalidMessage) }
                else { continuation.resume(returning: message["result"]) }
            }
        }
        if buffer.count > 262_144 { end(AgentError.invalidMessage) }
    }
    func close() { end(AgentError.closed) }
    private func end(_ error: Error) {
        guard !closed else { return }; closed = true
        for task in deadlines.values { task.cancel() }; deadlines.removeAll()
        let requests = pending.values; pending.removeAll()
        for continuation in requests { continuation.resume(throwing: error) }
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
        // Writer owns stdin closure so a blocked write is not raced with close.
        let oldInput = input; writer.async { try? oldInput?.close() }
        input = nil; buffer.removeAll()
        // EOF on stdout follows child termination; the reader closes its own handle.
    }
}

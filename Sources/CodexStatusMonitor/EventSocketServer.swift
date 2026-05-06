import Foundation
#if canImport(Darwin)
import Darwin
#endif

final class EventSocketServer: @unchecked Sendable {
    private let socketURL: URL
    private let queue = DispatchQueue(label: "local.codex.status-monitor.socket-server")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clientSources: [Int32: DispatchSourceRead] = [:]
    private var clientBuffers: [Int32: Data] = [:]
    private let onEvent: @Sendable (CodexStatusEvent) -> Void

    init(socketURL: URL, onEvent: @escaping @Sendable (CodexStatusEvent) -> Void) {
        self.socketURL = socketURL
        self.onEvent = onEvent
    }

    func start() {
        queue.async { self.startListening() }
    }

    func stop() {
        queue.async {
            self.acceptSource?.cancel()
            self.acceptSource = nil
            for (fd, src) in self.clientSources { src.cancel(); close(fd) }
            self.clientSources.removeAll()
            self.clientBuffers.removeAll()
            if self.listenFD >= 0 { close(self.listenFD); self.listenFD = -1 }
            unlink(self.socketURL.path)
        }
    }

    private func startListening() {
        ensureDirectory()
        unlink(socketURL.path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return }
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            path.withCString { cStr in
                ptr.baseAddress?.copyMemory(from: cStr, byteCount: strlen(cStr) + 1)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { close(fd); return }
        guard listen(fd, 10) == 0 else { close(fd); return }

        listenFD = fd

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptConnection() }
        src.setCancelHandler { close(fd) }
        src.resume()
        acceptSource = src
    }

    private func acceptConnection() {
        let clientFD = accept(listenFD, nil, nil)
        guard clientFD >= 0 else { return }

        clientBuffers[clientFD] = Data()

        let src = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: queue)
        src.setEventHandler { [weak self] in self?.readClient(fd: clientFD) }
        src.setCancelHandler { [weak self] in
            close(clientFD)
            self?.clientBuffers.removeValue(forKey: clientFD)
            self?.clientSources.removeValue(forKey: clientFD)
        }
        src.resume()
        clientSources[clientFD] = src
    }

    private func readClient(fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        if n <= 0 {
            clientSources[fd]?.cancel()
            return
        }
        clientBuffers[fd]?.append(contentsOf: buf[..<n])
        processLines(for: fd)
    }

    private func processLines(for fd: Int32) {
        guard var data = clientBuffers[fd] else { return }
        while let newline = data.firstIndex(of: 0x0A) {
            let line = data[..<newline]
            data.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            if let event = try? JSONDecoder().decode(CodexStatusEvent.self, from: Data(line)) {
                onEvent(event)
            }
        }
        clientBuffers[fd] = data
    }

    private func ensureDirectory() {
        let dir = socketURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}
